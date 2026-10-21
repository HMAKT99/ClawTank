//! Live clipboard file-transfer check against a running ClawTank (acts as an RDP client).
//!
//!   CLAWTANK_PASSWORD=… files_demo <host:port> <user> upload <MB>
//!       The client "copies" a generated folder (2 files, MB total); ClawTank downloads it.
//!       Prints SHA-256 of what was served, per file, to compare with the files on the Mac.
//!   CLAWTANK_PASSWORD=… files_demo <host:port> <user> download
//!       The client "pastes" whatever files are on the Mac's clipboard, fetching them in 1 MiB
//!       ranges, and prints throughput and SHA-256 per file.

#[path = "../tests/support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
use sha2::{Digest as _, Sha256};

#[derive(Debug, Default)]
struct Seen {
    asked_for_format_list: bool,
    remote_formats: Vec<(u32, Option<String>)>,
    remote_files: Option<(Vec<FileDescriptor>, Option<u32>)>,
    requests: Vec<FileContentsRequest>,
    responses: Vec<(u32, bool, Vec<u8>)>,
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
            | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED
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
    fn on_remote_file_list(&mut self, files: &[FileDescriptor], lock: Option<u32>) {
        self.0.lock().unwrap().remote_files = Some((files.to_vec(), lock));
    }
    fn on_format_data_request(&mut self, _r: FormatDataRequest) {}
    fn on_format_data_response(&mut self, _r: FormatDataResponse<'_>) {}
    fn on_file_contents_request(&mut self, request: FileContentsRequest) {
        self.0.lock().unwrap().requests.push(request);
    }
    fn on_file_contents_response(&mut self, r: FileContentsResponse<'_>) {
        self.0
            .lock()
            .unwrap()
            .responses
            .push((r.stream_id(), r.is_error(), r.data().to_vec()));
    }
    fn on_lock(&mut self, _id: LockDataId) {}
    fn on_unlock(&mut self, _id: LockDataId) {}
}

/// Deterministic test content: byte at `offset` of file `index`.
fn pattern(index: usize, offset: u64) -> u8 {
    ((offset.wrapping_mul(31) ^ (offset >> 12)) as u8).wrapping_add(index as u8 * 7)
}

async fn clip(
    stage: &mut ActiveStage,
    session: &mut client::Session,
    action: impl FnOnce(
        &mut CliprdrClient,
    ) -> ironrdp_pdu::PduResult<
        ironrdp_cliprdr::CliprdrSvcMessages<ironrdp_cliprdr::Client>,
    >,
) -> anyhow::Result<()> {
    let messages = action(
        stage
            .get_svc_processor_mut::<CliprdrClient>()
            .expect("cliprdr"),
    )?;
    let bytes = stage.process_svc_processor_messages(
        SvcProcessorMessages::<CliprdrClient>::new(messages.into()),
    )?;
    session.write_all(&bytes).await?;
    Ok(())
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(addr), Some(user), Some(mode)) = (args.first(), args.get(1), args.get(2)) else {
        anyhow::bail!("usage: files_demo <host:port> <user> upload <MB> | download");
    };
    let megabytes: u64 = args.get(3).map(|s| s.parse()).transpose()?.unwrap_or(64);
    let password = std::env::var("CLAWTANK_PASSWORD")?;
    let addr = std::net::ToSocketAddrs::to_socket_addrs(addr.as_str())?
        .next()
        .expect("address");

    let seen: Arc<Mutex<Seen>> = Arc::default();
    let backend_seen = Arc::clone(&seen);
    let config = client::client_config(user, &password, 1280, 800);
    let (result, mut session, _) = client::connect_with_channels(addr, config, None, move |c| {
        c.attach_static_channel(CliprdrClient::new(Box::new(Backend(backend_seen))));
    })
    .await?;
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 1280, 800);
    println!("connected ({mode})");

    let half = megabytes * 1024 * 1024 / 2;
    let names = ["probe-folder/part-a.bin", "probe-folder/part-b.bin"];
    let mut hashers = [Sha256::new(), Sha256::new()];
    let mut served = [0u64; 2];
    let start = Instant::now();
    let mut last_activity = Instant::now();
    let mut announced = false;
    let mut initialized = false;
    // download state
    let mut files: Vec<FileDescriptor> = Vec::new();
    let mut lock: Option<u32> = None;
    let mut current = 0usize;
    let mut position = 0u64;
    let mut waiting: Option<u32> = None;
    let mut stream = 100u32;
    let mut received_bytes = 0u64;
    let mut download_hasher = Sha256::new();
    let mut requested_list = false;
    let chunk: u64 = std::env::var("CHUNK_KB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1024)
        * 1024;

    loop {
        if mode == "upload" {
            if !initialized && seen.lock().unwrap().asked_for_format_list {
                clip(&mut stage, &mut session, |c| c.initiate_copy(&[])).await?;
                initialized = true;
            }
            if initialized && !announced {
                let mut dir = FileDescriptor::new("probe-folder");
                dir.attributes = Some(ironrdp_cliprdr::pdu::ClipboardFileAttributes::DIRECTORY);
                let mut a = FileDescriptor::new("part-a.bin");
                a.relative_path = Some("probe-folder".into());
                a.file_size = Some(half);
                let mut b = a.clone();
                b.name = "part-b.bin".into();
                // The channel becomes Ready once the server answers our initial format list.
                if clip(&mut stage, &mut session, |c| {
                    c.initiate_file_copy(vec![dir, a, b])
                })
                .await
                .is_ok()
                {
                    announced = true;
                    println!(
                        "copied a {megabytes} MB folder on the client; waiting for ClawTank to fetch it"
                    );
                }
            }
            let requests = std::mem::take(&mut seen.lock().unwrap().requests);
            for request in requests {
                last_activity = Instant::now();
                let file = usize::try_from(request.index - 1).unwrap_or(0).min(1); // index 0 is the folder
                let response = if request.flags.contains(FileContentsFlags::SIZE) {
                    FileContentsResponse::new_size_response(request.stream_id, half)
                } else {
                    let end = (request.position + u64::from(request.requested_size)).min(half);
                    let data: Vec<u8> = (request.position..end).map(|o| pattern(file, o)).collect();
                    if request.position == served[file] {
                        hashers[file].update(&data);
                        served[file] += data.len() as u64;
                    }
                    FileContentsResponse::new_data_response(request.stream_id, data)
                };
                clip(&mut stage, &mut session, |c| {
                    c.submit_file_contents(response)
                })
                .await?;
            }
            if served.iter().sum::<u64>() >= half * 2
                && last_activity.elapsed() > Duration::from_secs(2)
            {
                break;
            }
        } else {
            if !requested_list {
                let id = seen
                    .lock()
                    .unwrap()
                    .remote_formats
                    .iter()
                    .find(|(_, n)| n.as_deref() == Some("FileGroupDescriptorW"))
                    .map(|(id, _)| *id);
                if seen.lock().unwrap().asked_for_format_list && !announced {
                    clip(&mut stage, &mut session, |c| c.initiate_copy(&[])).await?;
                    announced = true;
                }
                if let Some(id) = id {
                    clip(&mut stage, &mut session, |c| {
                        c.initiate_paste(ClipboardFormatId::new(id))
                    })
                    .await?;
                    requested_list = true;
                }
            }
            if files.is_empty()
                && let Some((list, l)) = seen.lock().unwrap().remote_files.take()
            {
                files = list;
                lock = l;
                println!("Mac offered {} item(s); downloading", files.len());
            }
            // Handle arrived data *before* deciding to send, so the next request goes out at once.
            let responses = std::mem::take(&mut seen.lock().unwrap().responses);
            for (id, error, data) in responses {
                if Some(id) == waiting {
                    anyhow::ensure!(!error, "Mac reported an error for {}", files[current].name);
                    download_hasher.update(&data);
                    position += data.len() as u64;
                    received_bytes += data.len() as u64;
                    waiting = None;
                }
            }
            if !files.is_empty() && waiting.is_none() {
                while current < files.len()
                    && (files[current].file_size.unwrap_or(0) == 0
                        || position >= files[current].file_size.unwrap_or(0))
                {
                    if files[current].file_size.unwrap_or(0) > 0 {
                        let digest = std::mem::take(&mut download_hasher).finalize();
                        println!("  {}  {}", hex(&digest), files[current].name);
                    }
                    current += 1;
                    position = 0;
                }
                if current >= files.len() {
                    break;
                }
                stream += 1;
                let size = files[current].file_size.unwrap_or(0);
                let request = FileContentsRequest {
                    stream_id: stream,
                    index: i32::try_from(current)?,
                    flags: FileContentsFlags::RANGE,
                    position,
                    requested_size: u32::try_from((size - position).min(chunk))?,
                    data_id: lock,
                };
                clip(&mut stage, &mut session, |c| {
                    c.request_file_contents(request)
                })
                .await?;
                waiting = Some(stream);
            }
        }
        if start.elapsed() > Duration::from_secs(600) {
            anyhow::bail!("timed out");
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(20), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read?;
        for out in stage.process(&mut image, action, &payload)? {
            if let ActiveStageOutput::ResponseFrame(bytes) = out {
                session.write_all(&bytes).await?;
            }
        }
    }

    let secs = start.elapsed().as_secs_f64();
    if mode == "upload" {
        let total: u64 = served.iter().sum();
        println!(
            "served {total} bytes in {secs:.1} s ({:.1} MB/s)",
            total as f64 / secs / 1_048_576.0
        );
        for (hasher, name) in hashers.into_iter().zip(names) {
            println!("  {}  {name}", hex(&hasher.finalize()));
        }
    } else {
        println!(
            "received {received_bytes} bytes in {secs:.1} s ({:.1} MB/s)",
            received_bytes as f64 / secs / 1_048_576.0
        );
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
