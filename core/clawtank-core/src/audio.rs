//! System audio → client (MS-RDPEA / RDPSND).
//!
//! We advertise 16-bit PCM stereo at 48 kHz and 44.1 kHz; IronRDP negotiates with the client
//! and calls [`SoundHandler::start`] with the chosen format, which we report to the host as
//! `AudioStart`. The host then submits interleaved PCM chunks via [`AudioHub::submit_pcm`].
//! IronRDP itself drops stale chunks when the session falls behind, so latency can't grow.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use ironrdp_rdpsnd::pdu::{AudioFormat, WaveFormat};
use ironrdp_rdpsnd::server::{NegotiatedFormat, RdpsndError, RdpsndServerHandler};
use ironrdp_server::{RdpsndServerMessage, ServerEvent, ServerEventSender, SoundServerFactory};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{debug, info};

use crate::events::{CoreEvent, EventSink};

fn pcm(rate: u32, channels: u16) -> AudioFormat {
    let block_align = channels * 2;
    AudioFormat {
        format: WaveFormat::PCM,
        n_channels: channels,
        n_samples_per_sec: rate,
        n_avg_bytes_per_sec: rate * u32::from(block_align),
        n_block_align: block_align,
        bits_per_sample: 16,
        data: None,
    }
}

/// Shared between the sound factory/handler (IronRDP side) and the FFI (host side).
pub struct AudioHub {
    sink: EventSink,
    inner: Mutex<Inner>,
}

struct Inner {
    sender: Option<UnboundedSender<ServerEvent>>,
    /// (sample rate, channels) while the client is accepting audio.
    active: Option<(u32, u16)>,
    started: Instant,
}

impl AudioHub {
    pub fn new(sink: EventSink) -> Self {
        Self {
            sink,
            inner: Mutex::new(Inner {
                sender: None,
                active: None,
                started: Instant::now(),
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn start(&self, rate: u32, channels: u16) {
        {
            let mut inner = self.lock();
            inner.active = Some((rate, channels));
            inner.started = Instant::now();
        }
        info!(rate, channels, "Audio negotiated");
        (self.sink)(CoreEvent::AudioStart { rate, channels });
    }

    /// Session ended or the client closed the audio channel.
    pub fn stop(&self) {
        if self.lock().active.take().is_some() {
            info!("Audio stopped");
            (self.sink)(CoreEvent::AudioStop);
        }
    }

    /// The negotiated (rate, channels), if audio is on.
    pub fn format(&self) -> Option<(u32, u16)> {
        self.lock().active
    }

    /// Queues interleaved 16-bit little-endian PCM in the negotiated format. Returns false if
    /// audio isn't active (nothing is queued).
    pub fn submit_pcm(&self, pcm: &[u8]) -> bool {
        let inner = self.lock();
        let (Some(sender), Some(_)) = (inner.sender.as_ref(), inner.active) else {
            return false;
        };
        let ts = u32::try_from(inner.started.elapsed().as_millis()).unwrap_or(u32::MAX);
        sender
            .send(ServerEvent::Rdpsnd(RdpsndServerMessage::Wave(
                pcm.to_vec(),
                ts,
            )))
            .is_ok()
    }
}

pub struct SoundFactory {
    hub: Arc<AudioHub>,
}

impl SoundFactory {
    pub fn new(hub: Arc<AudioHub>) -> Self {
        Self { hub }
    }
}

impl ServerEventSender for SoundFactory {
    fn set_sender(&mut self, sender: UnboundedSender<ServerEvent>) {
        self.hub.lock().sender = Some(sender);
    }
}

impl SoundServerFactory for SoundFactory {
    fn build_backend(&self) -> Box<dyn RdpsndServerHandler> {
        Box::new(SoundHandler {
            hub: Arc::clone(&self.hub),
            formats: vec![pcm(48_000, 2), pcm(44_100, 2)],
        })
    }
}

struct SoundHandler {
    hub: Arc<AudioHub>,
    formats: Vec<AudioFormat>,
}

impl std::fmt::Debug for SoundHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SoundHandler").finish_non_exhaustive()
    }
}

impl RdpsndServerHandler for SoundHandler {
    fn get_formats(&self) -> &[AudioFormat] {
        &self.formats
    }

    fn choose_format<'a>(
        &mut self,
        common: &'a [NegotiatedFormat],
    ) -> Option<&'a NegotiatedFormat> {
        // `common` is in our preference order (48 kHz first).
        common.first()
    }

    fn start(&mut self, format: &NegotiatedFormat) -> Result<(), Box<dyn RdpsndError>> {
        let f = format.format();
        debug!(?f, "Starting audio");
        self.hub.start(f.n_samples_per_sec, f.n_channels);
        Ok(())
    }

    fn stop(&mut self) {
        self.hub.stop();
    }
}
