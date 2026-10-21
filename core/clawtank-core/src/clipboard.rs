//! Clipboard relay (MS-RDPECLIP / CLIPRDR) between the client and the host.
//!
//! This side only moves bytes: it announces the host's formats to the client, forwards the
//! client's format lists and data requests to the host, and hands back data. Format conversion
//! (UTF-16 text, RTF, CF_HTML, DIB images) is the host's job, next to NSPasteboard.
//!
//! One request to the client is outstanding at a time (CLIPRDR responses don't name their
//! format), so the hub remembers which format it asked for.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use ironrdp_cliprdr::backend::{ClipboardMessage, CliprdrBackend, CliprdrBackendFactory};
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardFormatName, ClipboardGeneralCapabilityFlags,
    FileContentsRequest, FileContentsResponse, FormatDataRequest, FormatDataResponse, LockDataId,
    OwnedFormatDataResponse,
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

    fn reset(&self, ready: bool) {
        let mut inner = self.lock();
        inner.ready = ready;
        inner.awaiting = None;
        inner.queued.clear();
        inner.received.clear();
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

    // File transfer arrives in Phase 7.
    fn on_file_contents_request(&mut self, _request: FileContentsRequest) {}
    fn on_file_contents_response(&mut self, _response: FileContentsResponse<'_>) {}
    fn on_lock(&mut self, _data_id: LockDataId) {}
    fn on_unlock(&mut self, _data_id: LockDataId) {}
}
