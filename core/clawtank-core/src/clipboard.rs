//! Clipboard relay (MS-RDPECLIP / CLIPRDR) between the client and the host.
//!
//! This side only moves bytes: it announces the host's formats to the client, forwards the
//! client's format lists and data requests to the host, and hands back data. Format conversion
//! (UTF-16 text, RTF, CF_HTML, DIB images) is the host's job, next to NSPasteboard.
//!
//! One request to the client is outstanding at a time (CLIPRDR responses don't name their
//! format), so the hub remembers which format it asked for.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use ironrdp_cliprdr::backend::{ClipboardMessage, CliprdrBackend, CliprdrBackendFactory};
use ironrdp_cliprdr::pdu::{
    ClipboardFileAttributes, ClipboardFormat, ClipboardFormatId, ClipboardFormatName,
    ClipboardGeneralCapabilityFlags, FileContentsFlags, FileContentsRequest, FileContentsResponse,
    FileDescriptor, FormatDataRequest, FormatDataResponse, LockDataId, OwnedFormatDataResponse,
};
use ironrdp_server::{CliprdrServerFactory, ServerEvent, ServerEventSender};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{debug, info, warn};

use crate::events::{CoreEvent, EventSink};

/// A clipboard format: a standard id (e.g. 13 = CF_UNICODETEXT) or a registered name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Format {
    pub id: u32,
    pub name: Option<String>,
}

/// One file or folder in a clipboard file list (paths use `/`, relative to the copied set).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    pub is_dir: bool,
}

/// What the client asked for in a file-contents request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileQuery {
    Size,
    Range { position: u64, length: u32 },
}

/// The host's answer to a file-contents request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileAnswer {
    Size(u64),
    Data(Vec<u8>),
    Error,
}

pub struct ClipboardHub {
    sink: EventSink,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    sender: Option<UnboundedSender<ServerEvent>>,
    ready: bool,
    /// Format we asked the client for, awaiting its response.
    awaiting: Option<u32>,
    /// Requests queued behind `awaiting`.
    queued: VecDeque<u32>,
    /// Data received from the client, waiting for the host to take it.
    received: VecDeque<(u32, Option<Vec<u8>>)>,
    /// Lock id for the client's current file list (sent back with each contents request).
    remote_lock: Option<u32>,
    next_stream: u32,
    /// File contents received from the client, by stream id.
    file_contents: HashMap<u32, Option<Vec<u8>>>,
}

impl ClipboardHub {
    pub fn new(sink: EventSink) -> Self {
        Self {
            sink,
            inner: Mutex::new(Inner::default()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn send(&self, message: ClipboardMessage) -> bool {
        let inner = self.lock();
        match (&inner.sender, inner.ready) {
            (Some(sender), true) => sender.send(ServerEvent::Clipboard(message)).is_ok(),
            _ => false,
        }
    }

    /// The host's clipboard changed: offer these formats to the client (data on request).
    pub fn announce(&self, formats: &[Format]) -> bool {
        let formats: Vec<ClipboardFormat> = formats
            .iter()
            .map(|f| {
                let format = ClipboardFormat::new(ClipboardFormatId::new(f.id));
                match &f.name {
                    Some(name) => format.with_name(ClipboardFormatName::new(name.clone())),
                    None => format,
                }
            })
            .collect();
        self.send(ClipboardMessage::SendInitiateCopy(formats))
    }

    /// Answers the client's latest data request (`None` = could not provide).
    pub fn provide(&self, data: Option<Vec<u8>>) -> bool {
        let response: OwnedFormatDataResponse = match data {
            Some(bytes) => FormatDataResponse::new_data(bytes),
            None => FormatDataResponse::new_error(),
        };
        self.send(ClipboardMessage::SendFormatData(response))
    }

    /// Asks the client for its clipboard in `format`; the answer arrives as `ClipboardData`.
    pub fn request(&self, format: u32) -> bool {
        let start_now = {
            let mut inner = self.lock();
            if !inner.ready {
                return false;
            }
            if inner.awaiting.is_some() {
                inner.queued.push_back(format);
                false
            } else {
                inner.awaiting = Some(format);
                true
            }
        };
        if start_now {
            return self.send(ClipboardMessage::SendInitiatePaste(ClipboardFormatId::new(
                format,
            )));
        }
        true
    }

    /// Takes the oldest data received from the client: (format, bytes or `None` on error).
    pub fn take_data(&self) -> Option<(u32, Option<Vec<u8>>)> {
        self.lock().received.pop_front()
    }

    fn on_response(&self, data: Option<Vec<u8>>) {
        let (format, next) = {
            let mut inner = self.lock();
            let Some(format) = inner.awaiting.take() else {
                warn!("Clipboard data arrived without a pending request");
                return;
            };
            inner.received.push_back((format, data));
            let next = inner.queued.pop_front();
            inner.awaiting = next;
            (format, next)
        };
        (self.sink)(CoreEvent::ClipboardData { format });
        if let Some(next) = next {
            self.send(ClipboardMessage::SendInitiatePaste(ClipboardFormatId::new(
                next,
            )));
        }
    }

    // ---- files ---------------------------------------------------------------------------

    /// The host copied files: offer them to the client (contents served on request).
    pub fn announce_files(&self, files: &[FileEntry]) -> bool {
        let descriptors = files
            .iter()
            .map(|f| {
                let (dir, name) = match f.path.rsplit_once('/') {
                    Some((dir, name)) => (Some(dir.replace('/', "\\")), name.to_owned()),
                    None => (None, f.path.clone()),
                };
                let mut d = FileDescriptor::new(name);
                d.relative_path = dir;
                d.file_size = (!f.is_dir).then_some(f.size);
                d.attributes = Some(if f.is_dir {
                    ClipboardFileAttributes::DIRECTORY
                } else {
                    ClipboardFileAttributes::NORMAL
                });
                d
            })
            .collect();
        self.send(ClipboardMessage::SendInitiateFileCopy(descriptors))
    }

    /// Answers a file-contents request from the client.
    pub fn answer_file_contents(&self, stream_id: u32, answer: FileAnswer) -> bool {
        let response = match answer {
            FileAnswer::Size(size) => FileContentsResponse::new_size_response(stream_id, size),
            FileAnswer::Data(data) => FileContentsResponse::new_data_response(stream_id, data),
            FileAnswer::Error => FileContentsResponse::new_error(stream_id),
        };
        self.send(ClipboardMessage::SendFileContentsResponse(response))
    }

    /// Asks the client for file `index` of its current file list. Returns the stream id the
    /// answer will carry (`FileContents` event), or `None` if the channel isn't ready.
    pub fn request_file_contents(&self, index: u32, query: FileQuery) -> Option<u32> {
        let (stream_id, lock) = {
            let mut inner = self.lock();
            if !inner.ready {
                return None;
            }
            inner.next_stream = inner.next_stream.wrapping_add(1).max(1);
            (inner.next_stream, inner.remote_lock)
        };
        let (flags, position, requested_size) = match query {
            FileQuery::Size => (FileContentsFlags::SIZE, 0, 8),
            FileQuery::Range { position, length } => (FileContentsFlags::RANGE, position, length),
        };
        let request = FileContentsRequest {
            stream_id,
            index: i32::try_from(index).ok()?,
            flags,
            position,
            requested_size,
            data_id: lock,
        };
        self.send(ClipboardMessage::SendFileContentsRequest(request))
            .then_some(stream_id)
    }

    /// Takes file contents received for `stream_id` (`Some(None)` = the client reported an error).
    pub fn take_file_contents(&self, stream_id: u32) -> Option<Option<Vec<u8>>> {
        self.lock().file_contents.remove(&stream_id)
    }

    fn on_file_list(&self, files: &[FileDescriptor], lock: Option<u32>) {
        let entries = files
            .iter()
            .map(|f| {
                let path = match &f.relative_path {
                    Some(dir) if !dir.is_empty() => {
                        format!("{}/{}", dir.replace('\\', "/"), f.name)
                    }
                    _ => f.name.clone(),
                };
                let is_dir = f
                    .attributes
                    .is_some_and(|a| a.contains(ClipboardFileAttributes::DIRECTORY));
                FileEntry {
                    path,
                    size: f.file_size.unwrap_or(0),
                    is_dir,
                }
            })
            .collect();
        let next = {
            let mut inner = self.lock();
            inner.remote_lock = lock;
            // The file list *is* the response to our FileGroupDescriptorW request.
            inner.awaiting = inner.queued.pop_front();
            inner.awaiting
        };
        (self.sink)(CoreEvent::ClipboardRemoteFiles(entries));
        if let Some(next) = next {
            self.send(ClipboardMessage::SendInitiatePaste(ClipboardFormatId::new(
                next,
            )));
        }
    }

    fn on_file_contents(&self, response: &FileContentsResponse<'_>) {
        let stream_id = response.stream_id();
        let data = (!response.is_error()).then(|| response.data().to_vec());
        self.lock().file_contents.insert(stream_id, data);
        (self.sink)(CoreEvent::ClipboardFileContents { stream_id });
    }

    /// Drives the clipboard's lock/transfer timeouts once a second (IronRDP #2148).
    fn spawn_timeout_driver(hub: &Arc<Self>) {
        let weak: Weak<Self> = Arc::downgrade(hub);
        let _ = std::thread::Builder::new()
            .name("clawtank-cliprdr-timer".to_owned())
            .spawn(move || {
                while let Some(hub) = weak.upgrade() {
                    if hub.lock().ready {
                        let _ = hub.sender_event(ServerEvent::CliprdrDriveTimeouts);
                    }
                    drop(hub);
                    std::thread::sleep(Duration::from_secs(1));
                }
            });
    }

    fn sender_event(&self, event: ServerEvent) -> bool {
        self.lock()
            .sender
            .as_ref()
            .is_some_and(|s| s.send(event).is_ok())
    }

    fn reset(&self, ready: bool) {
        let mut inner = self.lock();
        inner.ready = ready;
        inner.awaiting = None;
        inner.queued.clear();
        inner.received.clear();
        inner.remote_lock = None;
        inner.file_contents.clear();
    }

    /// Session ended.
    pub fn session_ended(&self) {
        self.reset(false);
    }
}

pub struct ClipboardFactory {
    hub: Arc<ClipboardHub>,
}

impl ClipboardFactory {
    pub fn new(hub: Arc<ClipboardHub>) -> Self {
        Self { hub }
    }
}

impl ServerEventSender for ClipboardFactory {
    fn set_sender(&mut self, sender: UnboundedSender<ServerEvent>) {
        self.hub.lock().sender = Some(sender);
        ClipboardHub::spawn_timeout_driver(&self.hub);
    }
}

impl CliprdrBackendFactory for ClipboardFactory {
    fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
        Box::new(Backend {
            hub: Arc::clone(&self.hub),
            temp_dir: std::env::temp_dir().to_string_lossy().into_owned(),
        })
    }
}

impl CliprdrServerFactory for ClipboardFactory {}

#[derive(Debug)]
struct Backend {
    hub: Arc<ClipboardHub>,
    temp_dir: String,
}

ironrdp_core::impl_as_any!(Backend);

impl std::fmt::Debug for ClipboardHub {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClipboardHub").finish_non_exhaustive()
    }
}

impl CliprdrBackend for Backend {
    fn temporary_directory(&self) -> &str {
        &self.temp_dir
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        ClipboardGeneralCapabilityFlags::USE_LONG_FORMAT_NAMES
            | ClipboardGeneralCapabilityFlags::STREAM_FILECLIP_ENABLED
            | ClipboardGeneralCapabilityFlags::FILECLIP_NO_FILE_PATHS
            | ClipboardGeneralCapabilityFlags::CAN_LOCK_CLIPDATA
            | ClipboardGeneralCapabilityFlags::HUGE_FILE_SUPPORT_ENABLED
    }

    fn on_ready(&mut self) {
        info!("Clipboard channel ready");
        self.hub.reset(true);
        (self.hub.sink)(CoreEvent::ClipboardReady);
    }

    fn on_request_format_list(&mut self) {
        // The client wants to know what we have: the host re-announces its clipboard.
        (self.hub.sink)(CoreEvent::ClipboardReady);
    }

    fn on_process_negotiated_capabilities(
        &mut self,
        capabilities: ClipboardGeneralCapabilityFlags,
    ) {
        debug!(?capabilities, "Clipboard capabilities");
    }

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        let formats = available_formats
            .iter()
            .map(|f| Format {
                id: f.id().value(),
                name: f.name().map(|n| n.value().to_owned()),
            })
            .collect();
        (self.hub.sink)(CoreEvent::ClipboardRemoteFormats(formats));
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        (self.hub.sink)(CoreEvent::ClipboardDataRequested {
            format: request.format.value(),
        });
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        let data = (!response.is_error()).then(|| response.data().to_vec());
        self.hub.on_response(data);
    }

    fn on_remote_file_list(&mut self, files: &[FileDescriptor], clip_data_id: Option<u32>) {
        self.hub.on_file_list(files, clip_data_id);
    }

    fn on_file_contents_request(&mut self, request: FileContentsRequest) {
        let query = if request.flags.contains(FileContentsFlags::SIZE) {
            FileQuery::Size
        } else {
            FileQuery::Range {
                position: request.position,
                length: request.requested_size,
            }
        };
        match u32::try_from(request.index) {
            Ok(index) => (self.hub.sink)(CoreEvent::ClipboardFileRequested {
                stream_id: request.stream_id,
                index,
                query,
            }),
            Err(_) => {
                self.hub
                    .answer_file_contents(request.stream_id, FileAnswer::Error);
            }
        }
    }

    fn on_file_contents_response(&mut self, response: FileContentsResponse<'_>) {
        self.hub.on_file_contents(&response);
    }

    // Locks are managed by IronRDP's Cliprdr (it holds them per file list); nothing to do.
    fn on_lock(&mut self, _data_id: LockDataId) {}
    fn on_unlock(&mut self, _data_id: LockDataId) {}
}
