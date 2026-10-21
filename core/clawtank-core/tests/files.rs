//! End-to-end clipboard file transfer (MS-RDPECLIP file streams), both directions, with
//! IronRDP's CLIPRDR client: host → client (announce files, client fetches the list, a size
//! and a byte range) and client → host (client copies a file; host gets the list and a range).

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clawtank_core::access::AccessPolicy;
use clawtank_core::clipboard::{FileAnswer, FileEntry, FileQuery};
use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig};
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
use ironrdp_session::image::DecodedImage;
use ironrdp_session::{ActiveStage, ActiveStageOutput};
use ironrdp_svc::SvcProcessorMessages;

#[derive(Debug, Default)]
struct Seen {
    asked_for_format_list: bool,
    remote_formats: Vec<(u32, Option<String>)>,
    remote_files: Vec<FileDescriptor>,
    contents: Vec<(u32, Vec<u8>)>,
    requests: Vec<FileContentsRequest>,
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
            | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
    }
    fn on_ready(&mut self) {}
    fn on_request_format_list(&mut self) {
        self.0.lock().unwrap().asked_for_format_list = true;
    }
    fn on_process_negotiated_capabilities(&mut self, _c: ClipboardGeneralCapabilityFlags) {}
    fn on_remote_copy(&mut self, formats: &[ClipboardFormat]) {
        self.0.lock().unwrap().remote_formats = formats
            .iter()
            .map(|f| (f.id().value(), f.name().map(|n| n.value().to_owned())))
            .collect();
    }
    fn on_remote_file_list(&mut self, files: &[FileDescriptor], _lock: Option<u32>) {
        self.0.lock().unwrap().remote_files = files.to_vec();
    }
    fn on_format_data_request(&mut self, _r: FormatDataRequest) {}
    fn on_format_data_response(&mut self, _r: FormatDataResponse<'_>) {}
    fn on_file_contents_request(&mut self, request: FileContentsRequest) {
        self.0.lock().unwrap().requests.push(request);
    }
    fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
        self.0
            .lock()
            .unwrap()
            .contents
            .push((response.stream_id(), response.data().to_vec()));
    }
    fn on_lock(&mut self, _id: LockDataId) {}
    fn on_unlock(&mut self, _id: LockDataId) {}
}

async fn clip(
    stage: &mut ActiveStage,
    session: &mut client::Session,
    action: impl FnOnce(
        &mut CliprdrClient,
    ) -> ironrdp_pdu::PduResult<
        ironrdp_cliprdr::CliprdrSvcMessages<ironrdp_cliprdr::Client>,
    >,
) {
    let messages =
        action(stage.get_svc_processor_mut::<CliprdrClient>().unwrap()).expect("cliprdr");
    let bytes = stage
        .process_svc_processor_messages(SvcProcessorMessages::<CliprdrClient>::new(messages.into()))
        .unwrap();
    session.write_all(&bytes).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn files_both_ways() {
    let events: Arc<Mutex<Vec<CoreEvent>>> = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: "tester".to_owned(),
        password: "files-password".to_owned(),
        identity: TlsIdentity::generate("files.local").unwrap(),
        policy: AccessPolicy::lan_only(),
    };
    let server = server::start(
        config,
        Arc::new(move |e| log.lock().unwrap().push(e)),
        Arc::new(|_| {}),
    )
    .unwrap();
    let find = |pred: &dyn Fn(&CoreEvent) -> bool| {
        events.lock().unwrap().iter().find(|e| pred(e)).cloned()
    };

    let seen: Arc<Mutex<Seen>> = Arc::default();
    let backend_seen = Arc::clone(&seen);
    let config = client::client_config("tester", "files-password", 800, 600);
    let (result, mut session, _) =
        client::connect_with_channels(server.local_addr(), config, None, move |c| {
            c.attach_static_channel(CliprdrClient::new(Box::new(Backend(backend_seen))));
        })
        .await
        .unwrap();
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 800, 600);

    let host_files = vec![
        FileEntry {
            path: "notes.txt".into(),
            size: 11,
            is_dir: false,
        },
        FileEntry {
            path: "photos".into(),
            size: 0,
            is_dir: true,
        },
        FileEntry {
            path: "photos/cat.bin".into(),
            size: 5,
            is_dir: false,
        },
    ];
    let client_bytes = b"bytes from the client side".to_vec();
    let mut step = 0;
    let mut stream_for_host = 0;
    let deadline = Instant::now() + Duration::from_secs(20);
    while step != 99 && Instant::now() < deadline {
        match step {
            0 if seen.lock().unwrap().asked_for_format_list => {
                clip(&mut stage, &mut session, |c| c.initiate_copy(&[])).await;
                step = 1;
            }
            1 if find(&|e| matches!(e, CoreEvent::ClipboardReady)).is_some() => {
                assert!(server.clipboard().announce_files(&host_files));
                step = 2;
            }
            // Host → client: fetch the file list by its FileGroupDescriptorW format id.
            2 => {
                let id = seen
                    .lock()
                    .unwrap()
                    .remote_formats
                    .iter()
                    .find(|(_, n)| n.as_deref() == Some("FileGroupDescriptorW"))
                    .map(|(id, _)| *id);
                if let Some(id) = id {
                    clip(&mut stage, &mut session, |c| {
                        c.initiate_paste(ClipboardFormatId::new(id))
                    })
                    .await;
                    step = 3;
                }
            }
            3 if seen.lock().unwrap().remote_files.len() == 3 => {
                let files = seen.lock().unwrap().remote_files.clone();
                assert_eq!(files[0].name, "notes.txt");
                assert_eq!(files[2].name, "cat.bin");
                assert_eq!(files[2].relative_path.as_deref(), Some("photos"));
                let request = |stream_id, flags, position, requested_size| FileContentsRequest {
                    stream_id,
                    index: 2,
                    flags,
                    position,
                    requested_size,
                    data_id: None,
                };
                clip(&mut stage, &mut session, |c| {
                    c.request_file_contents(request(7, FileContentsFlags::SIZE, 0, 8))
                })
                .await;
                clip(&mut stage, &mut session, |c| {
                    c.request_file_contents(request(8, FileContentsFlags::RANGE, 1, 3))
                })
                .await;
                step = 4;
            }
            4 => {
                // Answer whatever the server forwarded.
                let requests: Vec<_> = events
                    .lock()
                    .unwrap()
                    .iter()
                    .filter_map(|e| match e {
                        CoreEvent::ClipboardFileRequested {
                            stream_id,
                            index,
                            query,
                        } => Some((*stream_id, *index, *query)),
                        _ => None,
                    })
                    .collect();
                for (stream_id, index, query) in requests {
                    assert_eq!(index, 2);
                    let answer = match query {
                        FileQuery::Size => FileAnswer::Size(5),
                        FileQuery::Range {
                            position: 1,
                            length: 3,
                        } => FileAnswer::Data(b"ell".to_vec()),
                        other => panic!("unexpected {other:?}"),
                    };
                    server.clipboard().answer_file_contents(stream_id, answer);
                }
                let contents = seen.lock().unwrap().contents.clone();
                if contents.len() >= 2 {
                    assert!(
                        contents.contains(&(7, 5u64.to_le_bytes().to_vec())),
                        "size answer"
                    );
                    assert!(contents.contains(&(8, b"ell".to_vec())), "range answer");
                    // Client → host: client copies one file.
                    let mut file = FileDescriptor::new("report.pdf");
                    file.file_size = Some(client_bytes.len() as u64);
                    clip(&mut stage, &mut session, |c| {
                        c.initiate_file_copy(vec![file])
                    })
                    .await;
                    events
                        .lock()
                        .unwrap()
                        .retain(|e| !matches!(e, CoreEvent::ClipboardFileRequested { .. }));
                    step = 5;
                }
            }
            5 => {
                if let Some(CoreEvent::ClipboardRemoteFormats(formats)) =
                    find(&|e| matches!(e, CoreEvent::ClipboardRemoteFormats(f) if !f.is_empty()))
                {
                    let id = formats
                        .iter()
                        .find(|f| f.name.as_deref() == Some("FileGroupDescriptorW"))
                        .expect("client offered files")
                        .id;
                    assert!(server.clipboard().request(id));
                    step = 6;
                }
            }
            6 => {
                if let Some(CoreEvent::ClipboardRemoteFiles(files)) =
                    find(&|e| matches!(e, CoreEvent::ClipboardRemoteFiles(_)))
                {
                    assert_eq!(
                        files,
                        vec![FileEntry {
                            path: "report.pdf".into(),
                            size: client_bytes.len() as u64,
                            is_dir: false
                        }]
                    );
                    stream_for_host = server
                        .clipboard()
                        .request_file_contents(
                            0,
                            FileQuery::Range {
                                position: 0,
                                length: client_bytes.len() as u32,
                            },
                        )
                        .expect("request");
                    step = 7;
                }
            }
            7 => {
                let request = seen.lock().unwrap().requests.pop();
                if let Some(request) = request {
                    assert_eq!(request.index, 0);
                    let response = FileContentsResponse::new_data_response(
                        request.stream_id,
                        client_bytes.clone(),
                    );
                    clip(&mut stage, &mut session, |c| {
                        c.submit_file_contents(response)
                    })
                    .await;
                    step = 8;
                }
            }
            8 => {
                if let Some(data) = server.clipboard().take_file_contents(stream_for_host) {
                    assert_eq!(data, Some(client_bytes.clone()));
                    step = 99;
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
        99,
        "stuck at step {step}; events: {:?}",
        events.lock().unwrap()
    );
    drop(session);
    server.stop();
}
