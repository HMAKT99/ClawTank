//! Routes the core's `tracing` output to a host-supplied callback (os.Logger on macOS).
//!
//! Installed at most once per process. Each formatted event becomes one callback call with
//! its level, so the host can map levels to its own logging categories.

use std::io::Write;
use std::sync::OnceLock;

use tracing::{Level, Metadata};
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;

pub type LogFn = Box<dyn Fn(Level, &str) + Send + Sync>;

static SINK: OnceLock<LogFn> = OnceLock::new();

/// Installs the global subscriber. `filter` uses `EnvFilter` syntax (e.g. `"info,ironrdp=warn"`).
/// Returns `false` if logging was already installed (by this or any other subscriber).
pub fn install(sink: LogFn, filter: &str) -> bool {
    if SINK.set(sink).is_err() {
        return false;
    }
    let filter = EnvFilter::try_new(filter).unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_writer(CallbackMakeWriter)
        .with_env_filter(filter)
        .with_ansi(false)
        .without_time()
        .with_level(false)
        .try_init()
        .is_ok()
}

struct CallbackMakeWriter;

impl<'a> MakeWriter<'a> for CallbackMakeWriter {
    type Writer = CallbackWriter;

    fn make_writer(&'a self) -> Self::Writer {
        CallbackWriter::new(Level::INFO)
    }

    fn make_writer_for(&'a self, meta: &Metadata<'_>) -> Self::Writer {
        CallbackWriter::new(*meta.level())
    }
}

/// Buffers one formatted event and hands it to the sink when dropped.
struct CallbackWriter {
    level: Level,
    buf: Vec<u8>,
}

impl CallbackWriter {
    fn new(level: Level) -> Self {
        Self {
            level,
            buf: Vec::with_capacity(256),
        }
    }
}

impl Write for CallbackWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for CallbackWriter {
    fn drop(&mut self) {
        if let Some(sink) = SINK.get() {
            let text = String::from_utf8_lossy(&self.buf);
            let text = text.trim_end();
            if !text.is_empty() {
                sink(self.level, text);
            }
        }
    }
}
