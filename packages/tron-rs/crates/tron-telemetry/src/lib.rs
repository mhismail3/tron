mod logging;
mod metrics;

pub use logging::{LogQuery, LogRecord, SqliteLogLayer, SqliteLogSink};
pub use metrics::{HistogramSummary, MetricType, MetricsQuery, MetricsRecorder, MetricsSnapshot};

use std::path::PathBuf;
use std::sync::Arc;

use parking_lot::RwLock;
use tracing::Level;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

/// Configuration for the telemetry subsystem.
#[derive(Clone, Debug)]
pub struct TelemetryConfig {
    /// Default log level. Overridden by RUST_LOG env var.
    pub log_level: Level,
    /// Per-module level overrides (e.g. "tron_llm" => DEBUG).
    pub module_levels: Vec<(String, Level)>,
    /// Whether to persist warn+ logs to SQLite.
    pub log_to_sqlite: bool,
    /// Path to the log database.
    pub log_db_path: PathBuf,
    /// Whether metrics recording is enabled.
    pub metrics_enabled: bool,
    /// Path to the metrics database.
    pub metrics_db_path: PathBuf,
    /// How often to snapshot metrics to SQLite (seconds).
    pub metrics_snapshot_interval_secs: u64,
    /// How many days of metrics to retain.
    pub metrics_retention_days: u32,
}

impl Default for TelemetryConfig {
    fn default() -> Self {
        let tron_dir = dirs_fallback();
        Self {
            log_level: Level::INFO,
            module_levels: Vec::new(),
            log_to_sqlite: true,
            log_db_path: tron_dir.join("database/rs-logs.db"),
            metrics_enabled: true,
            metrics_db_path: tron_dir.join("database/rs-metrics.db"),
            metrics_snapshot_interval_secs: 60,
            metrics_retention_days: 7,
        }
    }
}

/// Guard that flushes telemetry on drop.
pub struct TelemetryGuard {
    log_sink: Option<Arc<SqliteLogSink>>,
    metrics_recorder: Option<Arc<MetricsRecorder>>,
    level_filter: Arc<RwLock<Vec<(String, Level)>>>,
}

impl TelemetryGuard {
    /// Change the log level for a specific module at runtime.
    pub fn set_module_level(&self, module: &str, level: Level) {
        let mut levels = self.level_filter.write();
        if let Some(entry) = levels.iter_mut().find(|(m, _)| m == module) {
            entry.1 = level;
        } else {
            levels.push((module.to_string(), level));
        }
    }

    /// Get current per-module log level overrides.
    pub fn module_levels(&self) -> Vec<(String, Level)> {
        self.level_filter.read().clone()
    }

    /// Access the metrics recorder for recording and querying.
    pub fn metrics(&self) -> Option<&MetricsRecorder> {
        self.metrics_recorder.as_deref()
    }

    /// Access the log sink for querying persisted logs.
    pub fn logs(&self) -> Option<&SqliteLogSink> {
        self.log_sink.as_deref()
    }
}

/// Initialize the telemetry subsystem. Call once at startup.
pub fn init_telemetry(config: TelemetryConfig) -> TelemetryGuard {
    let level_filter = Arc::new(RwLock::new(config.module_levels.clone()));

    // Build the env filter from config
    let mut filter_str = config.log_level.to_string().to_lowercase();
    for (module, level) in &config.module_levels {
        filter_str.push_str(&format!(",{}={}", module, level.to_string().to_lowercase()));
    }
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(&filter_str));

    // JSON formatting layer for stdout
    let fmt_layer = tracing_subscriber::fmt::layer()
        .json()
        .with_target(true)
        .with_span_list(true)
        .with_filter(env_filter);

    // Optional SQLite log sink for warn+ logs
    let (sqlite_layer, sqlite_sink) = if config.log_to_sqlite {
        match SqliteLogSink::new(&config.log_db_path) {
            Ok(sink) => {
                let sink = Arc::new(sink);
                let layer = SqliteLogLayer::new(sink.clone());
                (Some(layer), Some(sink))
            }
            Err(e) => {
                eprintln!("tron-telemetry: failed to open log DB: {e}");
                (None, None)
            }
        }
    } else {
        (None, None)
    };

    // Initialize tracing subscriber
    tracing_subscriber::registry()
        .with(fmt_layer)
        .with(sqlite_layer)
        .init();

    // Optional metrics recorder
    let metrics_recorder = if config.metrics_enabled {
        match MetricsRecorder::new(&config.metrics_db_path) {
            Ok(recorder) => Some(Arc::new(recorder)),
            Err(e) => {
                tracing::warn!("tron-telemetry: failed to open metrics DB: {e}");
                None
            }
        }
    } else {
        None
    };

    TelemetryGuard {
        log_sink: sqlite_sink,
        metrics_recorder,
        level_filter,
    }
}

/// Fallback home dir for default paths.
fn dirs_fallback() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
        .join(".tron")
}
