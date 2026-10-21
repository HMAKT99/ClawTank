//! End-to-end audio + clipboard: an IronRDP client with RDPSND and CLIPRDR channels connects.
//! Audio: the server negotiates 48 kHz stereo PCM and submitted PCM reaches the client intact.
//! Clipboard, both directions: host → client (announce, client pastes, host provides) and
//! client → host (client copies, host requests, client provides).

#[path = "support/client.rs"]
mod client;

use std::borrow::Cow;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clawtank_core::access::AccessPolicy;
use clawtank_core::clipboard::Format;
use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig};
use clawtank_core::tls::TlsIdentity;
use ironrdp_async::FramedWrite as _;
use ironrdp_cliprdr::CliprdrClient;
use ironrdp_cliprdr::backend::CliprdrBackend;
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest,
    FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId,
};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_rdpsnd::client::{Rdpsnd, RdpsndClientHandler};
use ironrdp_rdpsnd::pdu::{AudioFormat, PitchPdu, VolumePdu, WaveFormat};
use ironrdp_session::image::DecodedImage;
use ironrdp_session::{ActiveStage, ActiveStageOutput};
use ironrdp_svc::SvcProcessorMessages;

const CF_UNICODETEXT: u32 = 13;

fn utf16z(text: &str) -> Vec<u8> {
    text.encode_utf16()
        .chain([0])
        .flat_map(u16::to_le_bytes)
        .collect()
}

// ---- audio client ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct AudioSeen {
    waves: Vec<Vec<u8>>,
}

#[derive(Debug)]
struct AudioClient {
    seen: Arc<Mutex<AudioSeen>>,
    formats: Vec<AudioFormat>,
}

impl RdpsndClientHandler for AudioClient {
    fn get_formats(&self) -> &[AudioFormat] {
        &self.formats
    }
    fn wave(&mut self, _format_no: usize, _ts: u32, data: Cow<'_, [u8]>) {
        self.seen.lock().unwrap().waves.push(data.into_owned());
    }
    fn set_volume(&mut self, _volume: VolumePdu) {}
    fn set_pitch(&mut self, _pitch: PitchPdu) {}
    fn close(&mut self) {}
}

// ---- clipboard client -----------------------------------------------------------------------

#[derive(Debug, Default)]
struct ClipSeen {
    ready: bool,
    asked_for_format_list: bool,
    remote_formats: Vec<u32>,
    data: Option<Vec<u8>>,
    requested: Option<u32>,
}

#[derive(Debug)]
struct ClipClient {
    seen: Arc<Mutex<ClipSeen>>,
}

ironrdp_core::impl_as_any!(ClipClient);

impl CliprdrBackend for ClipClient {
    fn temporary_directory(&self) -> &str {
        "/tmp"
    }
    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
    }
    fn on_ready(&mut self) {
        self.seen.lock().unwrap().ready = true;
    }
    fn on_request_format_list(&mut self) {
        self.seen.lock().unwrap().asked_for_format_list = true;
    }
    fn on_process_negotiated_capabilities(&mut self, _c: ClipboardGeneralCapabilityFlags) {}
    fn on_remote_copy(&mut self, formats: &[ClipboardFormat]) {
        self.seen.lock().unwrap().remote_formats = formats.iter().map(|f| f.id().value()).collect();
    }
    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        self.seen.lock().unwrap().requested = Some(request.format.value());
    }
    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        self.seen.lock().unwrap().data = Some(response.data().to_vec());
    }
    fn on_file_contents_request(&mut self, _r: FileContentsRequest) {}
    fn on_file_contents_response(&mut self, _r: FileContentsResponse<'_>) {}
    fn on_lock(&mut self, _id: LockDataId) {}
    fn on_unlock(&mut self, _id: LockDataId) {}
}

/// Runs a client-side clipboard action and writes the resulting PDUs.
async fn clip_send(
    stage: &mut ActiveStage,
    session: &mut client::Session,
    action: impl FnOnce(
        &mut CliprdrClient,
    ) -> ironrdp_pdu::PduResult<
        ironrdp_cliprdr::CliprdrSvcMessages<ironrdp_cliprdr::Client>,
    >,
) {
    let messages = {
        let cliprdr = stage
            .get_svc_processor_mut::<CliprdrClient>()
            .expect("cliprdr channel");
        action(cliprdr).expect("cliprdr action")
    };
    let bytes = stage
        .process_svc_processor_messages(SvcProcessorMessages::<CliprdrClient>::new(messages.into()))
        .expect("encode cliprdr");
    session.write_all(&bytes).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn audio_and_clipboard_round_trip() {
    let events: Arc<Mutex<Vec<CoreEvent>>> = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: "tester".to_owned(),
        password: "audio-clip-password".to_owned(),
        identity: TlsIdentity::generate("ac-test.local").unwrap(),
        policy: AccessPolicy::lan_only(),
    };
    let server = server::start(
        config,
        Arc::new(move |e| log.lock().unwrap().push(e)),
        Arc::new(|_| {}),
    )
    .unwrap();
    let has = |pred: &dyn Fn(&CoreEvent) -> bool| events.lock().unwrap().iter().any(pred);

    let audio_seen: Arc<Mutex<AudioSeen>> = Arc::default();
    let clip_seen: Arc<Mutex<ClipSeen>> = Arc::default();
    let mut config = client::client_config("tester", "audio-clip-password", 800, 600);
    config.enable_audio_playback = true;
    let (audio, clip) = (Arc::clone(&audio_seen), Arc::clone(&clip_seen));
    let (result, mut session, _) =
        client::connect_with_channels(server.local_addr(), config, None, move |c| {
            let pcm = AudioFormat {
                format: WaveFormat::PCM,
                n_channels: 2,
                n_samples_per_sec: 48_000,
                n_avg_bytes_per_sec: 192_000,
                n_block_align: 4,
                bits_per_sample: 16,
                data: None,
            };
            c.attach_static_channel(Rdpsnd::new(Box::new(AudioClient {
                seen: audio,
                formats: vec![pcm],
            })));
            c.attach_static_channel(CliprdrClient::new(Box::new(ClipClient { seen: clip })));
        })
        .await
        .expect("connect");
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 800, 600);

    let pcm: Vec<u8> = (0..960u32).flat_map(|i| (i as u16).to_le_bytes()).collect();
    let host_text = "hello from the Mac ✓";
    let client_text = "copied on the client";
    let mut step = 0;
    let deadline = Instant::now() + Duration::from_secs(20);
    while step != 7 && Instant::now() < deadline {
        match step {
            // Audio: negotiated, then PCM arrives byte-for-byte.
            0 if has(&|e| {
                matches!(
                    e,
                    CoreEvent::AudioStart {
                        rate: 48_000,
                        channels: 2
                    }
                )
            }) =>
            {
                assert!(server.audio().submit_pcm(&pcm));
                step = 1;
            }
            1 if audio_seen.lock().unwrap().waves.contains(&pcm) => step = 2,
            // Clipboard init: the client answers Monitor Ready with its (empty) format list…
            2 if clip_seen.lock().unwrap().asked_for_format_list => {
                clip_send(&mut stage, &mut session, |c| c.initiate_copy(&[])).await;
                step = 21;
            }
            // …then the server side is ready and the host can announce.
            21 if has(&|e| matches!(e, CoreEvent::ClipboardReady)) => {
                assert!(server.clipboard().announce(&[Format {
                    id: CF_UNICODETEXT,
                    name: None
                }]));
                step = 3;
            }
            // Host → client: client sees the format and pastes; host provides.
            3 if clip_seen.lock().unwrap().remote_formats == [CF_UNICODETEXT] => {
                clip_send(&mut stage, &mut session, |c| {
                    c.initiate_paste(ClipboardFormatId::new(CF_UNICODETEXT))
                })
                .await;
                step = 4;
            }
            4 if has(&|e| {
                matches!(
                    e,
                    CoreEvent::ClipboardDataRequested {
                        format: CF_UNICODETEXT
                    }
                )
            }) =>
            {
                assert!(server.clipboard().provide(Some(utf16z(host_text))));
                step = 5;
            }
            5 if clip_seen.lock().unwrap().data.as_deref()
                == Some(utf16z(host_text).as_slice()) =>
            {
                // Client → host: client copies; host requests; client provides.
                let formats = [ClipboardFormat::new(ClipboardFormatId::new(CF_UNICODETEXT))];
                clip_send(&mut stage, &mut session, |c| c.initiate_copy(&formats)).await;
                step = 6;
            }
            6 => {
                let announced = has(
                    &|e| matches!(e, CoreEvent::ClipboardRemoteFormats(f) if f.iter().any(|f| f.id == CF_UNICODETEXT)),
                );
                if announced && clip_seen.lock().unwrap().requested.is_none() {
                    server.clipboard().request(CF_UNICODETEXT);
                }
                if clip_seen.lock().unwrap().requested.take() == Some(CF_UNICODETEXT) {
                    let response = FormatDataResponse::new_data(utf16z(client_text));
                    clip_send(&mut stage, &mut session, |c| c.submit_format_data(response)).await;
                }
                if has(&|e| {
                    matches!(
                        e,
                        CoreEvent::ClipboardData {
                            format: CF_UNICODETEXT
                        }
                    )
                }) {
                    let (format, data) = server.clipboard().take_data().expect("data queued");
                    assert_eq!(format, CF_UNICODETEXT);
                    assert_eq!(data.as_deref(), Some(utf16z(client_text).as_slice()));
                    step = 7;
                }
            }
            _ => {}
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(50), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read.unwrap();
        for out in stage.process(&mut image, action, &payload).unwrap() {
            if let ActiveStageOutput::ResponseFrame(bytes) = out {
                session.write_all(&bytes).await.unwrap();
            }
        }
    }
    assert_eq!(
        step,
        7,
        "stuck at step {step}; events: {:?}",
        events.lock().unwrap()
    );
    drop(session);
    server.stop();
}
