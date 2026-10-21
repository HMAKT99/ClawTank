//! Measures clipboard file-transfer request latency through the core alone (no Swift):
//! the host answers each range request directly from the event callback. Ignored by default;
//! run with `cargo test --release --test file_throughput -- --ignored --nocapture`.

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use clawtank_core::access::AccessPolicy;
use clawtank_core::clipboard::{FileAnswer, FileEntry, FileQuery};
use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig, ServerHandle};
use clawtank_core::tls::TlsIdentity;
use ironrdp_async::FramedWrite as _;
use ironrdp_cliprdr::CliprdrClient;
use ironrdp_cliprdr::backend::CliprdrBackend;
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsFlags,
    FileContentsRequest, FileContentsResponse, FileDescriptor, FormatDataRequest,
    FormatDataResponse, LockDataId,
};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_session::ActiveStageOutput;
use ironrdp_session::image::DecodedImage;
use ironrdp_svc::SvcProcessorMessages;

#[derive(Debug, Default)]
struct Seen {
    asked: bool,
    formats: Vec<(u32, Option<String>)>,
    files: Option<Option<u32>>,
    responses: usize,
}

#[derive(Debug)]
struct Backend(Arc<Mutex<Seen>>);
ironrdp_core::impl_as_any!(Backend);

impl CliprdrBackend for Backend {
    fn temporary_directory(&self) -> &str {
        "/tmp"
    }
    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
            | ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
            | ClipboardGeneralCapabilityFlags::FILECLIP_NO_FILE_PATHS
    }
    fn on_ready(&mut self) {}
    fn on_request_format_list(&mut self) {
        self.0.lock().unwrap().asked = true;
    }
    fn on_process_negotiated_capabilities(&mut self, _c: ClipboardGeneralCapabilityFlags) {}
    fn on_remote_copy(&mut self, f: &[ClipboardFormat]) {
        self.0.lock().unwrap().formats = f
            .iter()
            .map(|f| (f.id().value(), f.name().map(|n| n.value().to_owned())))
            .collect();
    }
    fn on_remote_file_list(&mut self, _f: &[FileDescriptor], lock: Option<u32>) {
        self.0.lock().unwrap().files = Some(lock);
    }
    fn on_format_data_request(&mut self, _r: FormatDataRequest) {}
    fn on_format_data_response(&mut self, _r: FormatDataResponse<'_>) {}
    fn on_file_contents_request(&mut self, _r: FileContentsRequest) {}
    fn on_file_contents_response(&mut self, _r: FileContentsResponse<'_>) {
        self.0.lock().unwrap().responses += 1;
    }
    fn on_lock(&mut self, _id: LockDataId) {}
    fn on_unlock(&mut self, _id: LockDataId) {}
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn file_range_latency() {
    let handle: Arc<OnceLock<Arc<clawtank_core::clipboard::ClipboardHub>>> = Arc::default();
    let hub_for_events = Arc::clone(&handle);
    let chunk = vec![7u8; 1 << 20];
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: "t".into(),
        password: "throughput-pass".into(),
        identity: TlsIdentity::generate("t.local").unwrap(),
        policy: AccessPolicy::lan_only(),
    };
    let ready = Arc::new(Mutex::new(false));
    let ready_flag = Arc::clone(&ready);
    let server: ServerHandle = server::start(
        config,
        Arc::new(move |e| match e {
            CoreEvent::ClipboardReady => *ready_flag.lock().unwrap() = true,
            CoreEvent::ClipboardFileRequested {
                stream_id, query, ..
            } => {
                let hub = hub_for_events.get().unwrap();
                let answer = match query {
                    FileQuery::Size => FileAnswer::Size(100 << 20),
                    FileQuery::Range { length, .. } => {
                        FileAnswer::Data(chunk[..length as usize].to_vec())
                    }
                };
                hub.answer_file_contents(stream_id, answer);
            }
            _ => {}
        }),
        Arc::new(|_| {}),
    )
    .unwrap();
    handle.set(Arc::clone(server.clipboard())).ok();

    let seen: Arc<Mutex<Seen>> = Arc::default();
    let backend = Arc::clone(&seen);
    let (result, mut session, _) = client::connect_with_channels(
        server.local_addr(),
        client::client_config("t", "throughput-pass", 800, 600),
        None,
        move |c| c.attach_static_channel(CliprdrClient::new(Box::new(Backend(backend)))),
    )
    .await
    .unwrap();
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 800, 600);
    macro_rules! clip {
        ($f:expr) => {{
            let messages = $f(stage.get_svc_processor_mut::<CliprdrClient>().unwrap()).unwrap();
            let bytes = stage
                .process_svc_processor_messages(SvcProcessorMessages::<CliprdrClient>::new(
                    messages.into(),
                ))
                .unwrap();
            session.write_all(&bytes).await.unwrap();
        }};
    }
    let (mut phase, mut sent, mut started, mut stream) = (0, 0usize, Instant::now(), 0u32);
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        match phase {
            0 if seen.lock().unwrap().asked => {
                clip!(|c: &mut CliprdrClient| c.initiate_copy(&[]));
                phase = 1;
            }
            1 if *ready.lock().unwrap() => {
                server.clipboard().announce_files(&[FileEntry {
                    path: "big.bin".into(),
                    size: 100 << 20,
                    is_dir: false,
                }]);
                phase = 2;
            }
            2 => {
                let id = seen
                    .lock()
                    .unwrap()
                    .formats
                    .iter()
                    .find(|(_, n)| n.as_deref() == Some("FileGroupDescriptorW"))
                    .map(|f| f.0);
                if let Some(id) = id {
                    clip!(|c: &mut CliprdrClient| c.initiate_paste(ClipboardFormatId::new(id)));
                    phase = 3;
                }
            }
            3 if seen.lock().unwrap().files.is_some() => {
                started = Instant::now();
                phase = 4;
            }
            4 if seen.lock().unwrap().responses == sent => {
                if sent == 100 {
                    break;
                }
                stream += 1;
                let request = FileContentsRequest {
                    stream_id: stream,
                    index: 0,
                    flags: FileContentsFlags::RANGE,
                    position: (sent as u64) << 20,
                    requested_size: 1 << 20,
                    data_id: None,
                };
                clip!(|c: &mut CliprdrClient| c.request_file_contents(request));
                sent += 1;
            }
            _ => {}
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(20), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read.unwrap();
        for out in stage.process(&mut image, action, &payload).unwrap() {
            if let ActiveStageOutput::ResponseFrame(b) = out {
                session.write_all(&b).await.unwrap();
            }
        }
    }
    let per = started.elapsed() / 100;
    println!(
        "100 x 1 MiB: {:?} total, {:?} per request, {:.0} MB/s",
        started.elapsed(),
        per,
        100.0 / started.elapsed().as_secs_f64()
    );
    drop(session);
    server.stop();
}
