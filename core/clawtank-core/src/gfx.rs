//! IronRDP EGFX glue: the factory that builds a graphics pipeline per connection and the
//! handler that reports pipeline state to the [`VideoHub`].
//!
//! The handler runs with IronRDP's pipeline mutex held, so it only calls `VideoHub`'s
//! atomic-only callbacks (see the lock-order note in `video.rs`).

use std::sync::{Arc, Mutex};

use ironrdp_egfx::pdu::{CapabilitiesAdvertisePdu, CapabilitySet};
use ironrdp_egfx::server::{GraphicsPipelineHandler, GraphicsPipelineServer};
use ironrdp_server::{
    GfxDvcBridge, GfxServerFactory, GfxServerHandle, ServerEvent, ServerEventSender,
};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{debug, info};

use crate::video::VideoHub;

pub struct GfxFactory {
    hub: Arc<VideoHub>,
}

impl GfxFactory {
    pub fn new(hub: Arc<VideoHub>) -> Self {
        Self { hub }
    }
}

impl ServerEventSender for GfxFactory {
    fn set_sender(&mut self, sender: UnboundedSender<ServerEvent>) {
        self.hub.set_sender(sender);
    }
}

impl GfxServerFactory for GfxFactory {
    fn build_gfx_handler(&self) -> Box<dyn GraphicsPipelineHandler> {
        Box::new(GfxHandler {
            hub: Arc::clone(&self.hub),
        })
    }

    fn build_server_with_handle(&self) -> Option<(GfxDvcBridge, GfxServerHandle)> {
        let server: GfxServerHandle = Arc::new(Mutex::new(GraphicsPipelineServer::new(
            self.build_gfx_handler(),
        )));
        self.hub.attach(Arc::clone(&server));
        Some((GfxDvcBridge::new(Arc::clone(&server)), server))
    }
}

struct GfxHandler {
    hub: Arc<VideoHub>,
}

impl GraphicsPipelineHandler for GfxHandler {
    fn capabilities_advertise(&mut self, pdu: &CapabilitiesAdvertisePdu) {
        debug!(?pdu, "Client EGFX capabilities");
    }

    fn on_ready(&mut self, negotiated: &CapabilitySet) {
        info!(?negotiated, "EGFX capabilities negotiated");
        self.hub.on_ready();
    }

    fn on_frame_ack(&mut self, _frame_id: u32, _queue_depth: u32, _total_frames_decoded: u32) {
        self.hub.on_frame_ack();
    }

    fn on_close(&mut self) {
        self.hub.on_close();
    }
}
