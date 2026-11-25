//! IronRDP EGFX glue: the factory that builds a graphics pipeline per connection and the
//! handler that reports pipeline state to the [`VideoHub`].
//!
//! The handler runs with IronRDP's pipeline mutex held, so it only calls `VideoHub`'s
//! atomic-only callbacks (see the lock-order note in `video.rs`).

use std::sync::{Arc, Mutex};

use ironrdp_egfx::pdu::{
    CapabilitiesAdvertisePdu, CapabilitiesV8Flags, CapabilitiesV10Flags, CapabilitiesV81Flags,
    CapabilitiesV103Flags, CapabilitiesV104Flags, CapabilitiesV107Flags, CapabilitySet,
};
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

/// Capability sets we offer. IronRDP 0.3 confirms `client & server` flags of the best common
/// version, so `AVC_DISABLED` must be in our set for it to survive: clients such as the
/// Windows App / Microsoft Remote Desktop on Android and iOS advertise `AVC_DISABLED`
/// (no H.264 decoder), and if the flag is dropped we confirm AVC and send AVC420 frames,
/// which those clients answer with a "protocol error" disconnect.
/// For clients that don't set it (mstsc, Windows App on macOS/Windows) the result is unchanged.
/// The version ladder is IronRDP's default; only the flags differ.
pub(crate) fn preferred_capabilities() -> Vec<CapabilitySet> {
    vec![
        CapabilitySet::V10_7 {
            flags: CapabilitiesV107Flags::SMALL_CACHE | CapabilitiesV107Flags::AVC_DISABLED,
        },
        CapabilitySet::V10 {
            flags: CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED,
        },
        CapabilitySet::V8_1 {
            flags: CapabilitiesV81Flags::AVC420_ENABLED | CapabilitiesV81Flags::SMALL_CACHE,
        },
        CapabilitySet::V8 {
            flags: CapabilitiesV8Flags::SMALL_CACHE,
        },
    ]
}

/// Whether the confirmed capability set lets us send AVC420 (H.264) frames.
/// Mirrors MS-RDPEGFX 2.2.3: V8 has no AVC, V8.1 needs `AVC420_ENABLED`, V10.x unless
/// `AVC_DISABLED`.
pub(crate) fn avc420_allowed(caps: &CapabilitySet) -> bool {
    match caps {
        CapabilitySet::V8 { .. } => false,
        CapabilitySet::V8_1 { flags } => flags.contains(CapabilitiesV81Flags::AVC420_ENABLED),
        CapabilitySet::V10 { flags } | CapabilitySet::V10_2 { flags } => {
            !flags.contains(CapabilitiesV10Flags::AVC_DISABLED)
        }
        CapabilitySet::V10_1 => true,
        CapabilitySet::V10_3 { flags } => !flags.contains(CapabilitiesV103Flags::AVC_DISABLED),
        CapabilitySet::V10_4 { flags }
        | CapabilitySet::V10_5 { flags }
        | CapabilitySet::V10_6 { flags }
        | CapabilitySet::V10_6Err { flags } => !flags.contains(CapabilitiesV104Flags::AVC_DISABLED),
        CapabilitySet::V10_7 { flags } => !flags.contains(CapabilitiesV107Flags::AVC_DISABLED),
    }
}

impl GraphicsPipelineHandler for GfxHandler {
    fn capabilities_advertise(&mut self, pdu: &CapabilitiesAdvertisePdu) {
        debug!(?pdu, "Client EGFX capabilities");
    }

    fn preferred_capabilities(&self) -> Vec<CapabilitySet> {
        preferred_capabilities()
    }

    fn on_ready(&mut self, negotiated: &CapabilitySet) {
        let avc = avc420_allowed(negotiated);
        info!(?negotiated, avc, "EGFX capabilities negotiated");
        self.hub.on_ready(avc);
    }

    fn on_frame_ack(&mut self, frame_id: u32, _queue_depth: u32, _total_frames_decoded: u32) {
        self.hub.on_frame_ack(frame_id);
    }

    fn on_close(&mut self) {
        self.hub.on_close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// IronRDP 0.3's negotiation (`negotiate_capabilities`, private there): our versions in
    /// priority order, first one the client also offers, flags intersected.
    fn negotiate(client: &[CapabilitySet]) -> Option<CapabilitySet> {
        let ours = preferred_capabilities();
        ours.iter()
            .find_map(|s| {
                client
                    .iter()
                    .find(|c| c.version() == s.version())
                    .map(|c| (s, c))
            })
            .map(|(s, c)| match (c, s) {
                (CapabilitySet::V10_7 { flags: cf }, CapabilitySet::V10_7 { flags: sf }) => {
                    CapabilitySet::V10_7 { flags: *cf & *sf }
                }
                (CapabilitySet::V10 { flags: cf }, CapabilitySet::V10 { flags: sf }) => {
                    CapabilitySet::V10 { flags: *cf & *sf }
                }
                (CapabilitySet::V8_1 { flags: cf }, CapabilitySet::V8_1 { flags: sf }) => {
                    CapabilitySet::V8_1 { flags: *cf & *sf }
                }
                (CapabilitySet::V8 { flags: cf }, CapabilitySet::V8 { flags: sf }) => {
                    CapabilitySet::V8 { flags: *cf & *sf }
                }
                _ => s.clone(),
            })
    }

    #[test]
    fn android_client_keeps_avc_disabled() {
        // What the Windows App on Android/iOS advertises (no V10.7, AVC disabled).
        let client = [
            CapabilitySet::V8 {
                flags: CapabilitiesV8Flags::SMALL_CACHE,
            },
            CapabilitySet::V8_1 {
                flags: CapabilitiesV81Flags::SMALL_CACHE,
            },
            CapabilitySet::V10 {
                flags: CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED,
            },
            CapabilitySet::V10_4 {
                flags: CapabilitiesV104Flags::SMALL_CACHE | CapabilitiesV104Flags::AVC_DISABLED,
            },
        ];
        let negotiated = negotiate(&client).expect("common version");
        assert_eq!(
            negotiated,
            CapabilitySet::V10 {
                flags: CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED
            }
        );
        assert!(!avc420_allowed(&negotiated));
    }

    #[test]
    fn desktop_client_still_gets_avc() {
        let client = [
            CapabilitySet::V10 {
                flags: CapabilitiesV10Flags::SMALL_CACHE,
            },
            CapabilitySet::V10_7 {
                flags: CapabilitiesV107Flags::SMALL_CACHE,
            },
        ];
        let negotiated = negotiate(&client).expect("common version");
        assert_eq!(
            negotiated,
            CapabilitySet::V10_7 {
                flags: CapabilitiesV107Flags::SMALL_CACHE
            }
        );
        assert!(avc420_allowed(&negotiated));
    }

    #[test]
    fn avc_rules_per_version() {
        assert!(!avc420_allowed(&CapabilitySet::V8 {
            flags: CapabilitiesV8Flags::SMALL_CACHE
        }));
        assert!(!avc420_allowed(&CapabilitySet::V8_1 {
            flags: CapabilitiesV81Flags::SMALL_CACHE
        }));
        assert!(avc420_allowed(&CapabilitySet::V8_1 {
            flags: CapabilitiesV81Flags::AVC420_ENABLED
        }));
        assert!(avc420_allowed(&CapabilitySet::V10_1));
        assert!(!avc420_allowed(&CapabilitySet::V10_7 {
            flags: CapabilitiesV107Flags::AVC_DISABLED
        }));
    }
}
