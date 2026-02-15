use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

use chrono::Utc;
use parking_lot::{Mutex, RwLock};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

/// Type of metric.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MetricType {
    Counter,
    Gauge,
    Histogram,
}

/// A snapshot of a metric value at a point in time.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub id: i64,
    pub timestamp: String,
    pub name: String,
    pub value: f64,
    pub labels: Option<String>,
    pub metric_type: MetricType,
}

/// Query parameters for searching metrics.
#[derive(Clone, Debug, Default)]
pub struct MetricsQuery {
    pub name: Option<String>,
    pub since: Option<String>,
    pub labels: Option<HashMap<String, String>>,
    pub limit: Option<u32>,
}

/// In-memory counter. Monotonically increasing.
struct Counter {
    value: AtomicU64,
}

impl Counter {
    fn new() -> Self {
        Self {
            value: AtomicU64::new(0),
        }
    }
    fn increment(&self, n: u64) {
        self.value.fetch_add(n, Ordering::Relaxed);
    }
    fn get(&self) -> u64 {
        self.value.load(Ordering::Relaxed)
    }
}

/// In-memory gauge. Can go up or down.
struct Gauge {
    // Store as i64 bits to support negative values and atomics
    value: AtomicI64,
}

impl Gauge {
    fn new() -> Self {
        Self {
            value: AtomicI64::new(0),
        }
    }
    fn set(&self, v: f64) {
        self.value.store(v.to_bits() as i64, Ordering::Relaxed);
    }
    fn increment(&self, delta: f64) {
        loop {
            let current = self.value.load(Ordering::Relaxed);
            let current_f = f64::from_bits(current as u64);
            let new_f = current_f + delta;
            if self
                .value
                .compare_exchange_weak(
                    current,
                    new_f.to_bits() as i64,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                )
                .is_ok()
            {
                break;
            }
        }
    }
    fn get(&self) -> f64 {
        f64::from_bits(self.value.load(Ordering::Relaxed) as u64)
    }
}

/// In-memory histogram. Stores all observations for percentile computation.
struct Histogram {
    observations: Mutex<Vec<f64>>,
}

impl Histogram {
    fn new() -> Self {
        Self {
            observations: Mutex::new(Vec::new()),
        }
    }
    fn observe(&self, value: f64) {
        self.observations.lock().push(value);
    }
    fn summary(&self) -> HistogramSummary {
        let mut obs = self.observations.lock();
        if obs.is_empty() {
            return HistogramSummary::default();
        }
        obs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let count = obs.len();
        let sum: f64 = obs.iter().sum();
        let p50 = obs[count / 2];
        let p95 = obs[(count as f64 * 0.95) as usize];
        let p99 = obs[((count as f64 * 0.99) as usize).min(count - 1)];
        HistogramSummary {
            count: count as u64,
            sum,
            p50,
            p95,
            p99,
        }
    }
}

/// Summary statistics from a histogram.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HistogramSummary {
    pub count: u64,
    pub sum: f64,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
}

/// Metric key: name + labels.
#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct MetricKey {
    name: String,
    labels: Vec<(String, String)>,
}

impl MetricKey {
    fn new(name: impl Into<String>, labels: &[(&str, &str)]) -> Self {
        let mut sorted: Vec<(String, String)> = labels
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        Self {
            name: name.into(),
            labels: sorted,
        }
    }

    fn labels_json(&self) -> Option<String> {
        if self.labels.is_empty() {
            return None;
        }
        let map: HashMap<&str, &str> = self.labels.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        serde_json::to_string(&map).ok()
    }
}

/// Thread-safe metrics recorder backed by SQLite for historical snapshots.
pub struct MetricsRecorder {
    counters: RwLock<HashMap<MetricKey, Counter>>,
    gauges: RwLock<HashMap<MetricKey, Gauge>>,
    histograms: RwLock<HashMap<MetricKey, Histogram>>,
    db: Mutex<Connection>,
}

impl MetricsRecorder {
    pub fn new(db_path: &Path) -> Result<Self, rusqlite::Error> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS metrics_snapshots (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 timestamp TEXT NOT NULL,
                 name TEXT NOT NULL,
                 value REAL NOT NULL,
                 labels TEXT,
                 metric_type TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_metrics_name ON metrics_snapshots(name, timestamp);",
        )?;
        Ok(Self {
            counters: RwLock::new(HashMap::new()),
            gauges: RwLock::new(HashMap::new()),
            histograms: RwLock::new(HashMap::new()),
            db: Mutex::new(conn),
        })
    }

    /// Increment a counter by n.
    pub fn counter_inc(&self, name: &str, labels: &[(&str, &str)], n: u64) {
        let key = MetricKey::new(name, labels);
        let counters = self.counters.read();
        if let Some(c) = counters.get(&key) {
            c.increment(n);
            return;
        }
        drop(counters);
        let mut counters = self.counters.write();
        let c = counters.entry(key).or_insert_with(Counter::new);
        c.increment(n);
    }

    /// Set a gauge to a specific value.
    pub fn gauge_set(&self, name: &str, labels: &[(&str, &str)], value: f64) {
        let key = MetricKey::new(name, labels);
        let gauges = self.gauges.read();
        if let Some(g) = gauges.get(&key) {
            g.set(value);
            return;
        }
        drop(gauges);
        let mut gauges = self.gauges.write();
        let g = gauges.entry(key).or_insert_with(Gauge::new);
        g.set(value);
    }

    /// Increment/decrement a gauge by delta.
    pub fn gauge_inc(&self, name: &str, labels: &[(&str, &str)], delta: f64) {
        let key = MetricKey::new(name, labels);
        let gauges = self.gauges.read();
        if let Some(g) = gauges.get(&key) {
            g.increment(delta);
            return;
        }
        drop(gauges);
        let mut gauges = self.gauges.write();
        let g = gauges.entry(key).or_insert_with(Gauge::new);
        g.increment(delta);
    }

    /// Record a histogram observation.
    pub fn histogram_observe(&self, name: &str, labels: &[(&str, &str)], value: f64) {
        let key = MetricKey::new(name, labels);
        let histograms = self.histograms.read();
        if let Some(h) = histograms.get(&key) {
            h.observe(value);
            return;
        }
        drop(histograms);
        let mut histograms = self.histograms.write();
        let h = histograms.entry(key).or_insert_with(Histogram::new);
        h.observe(value);
    }

    /// Get a histogram summary.
    pub fn histogram_summary(&self, name: &str, labels: &[(&str, &str)]) -> HistogramSummary {
        let key = MetricKey::new(name, labels);
        let histograms = self.histograms.read();
        histograms
            .get(&key)
            .map(|h| h.summary())
            .unwrap_or_default()
    }

    /// Get current value of a counter.
    pub fn counter_get(&self, name: &str, labels: &[(&str, &str)]) -> u64 {
        let key = MetricKey::new(name, labels);
        self.counters.read().get(&key).map_or(0, |c| c.get())
    }

    /// Get current value of a gauge.
    pub fn gauge_get(&self, name: &str, labels: &[(&str, &str)]) -> f64 {
        let key = MetricKey::new(name, labels);
        self.gauges.read().get(&key).map_or(0.0, |g| g.get())
    }

    /// Take a snapshot of all current metric values and persist to SQLite.
    pub fn snapshot(&self) -> Result<usize, rusqlite::Error> {
        let now = Utc::now().to_rfc3339();
        let db = self.db.lock();
        let mut count = 0;

        // Snapshot counters
        let counters = self.counters.read();
        for (key, counter) in counters.iter() {
            db.execute(
                "INSERT INTO metrics_snapshots (timestamp, name, value, labels, metric_type)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![now, key.name, counter.get() as f64, key.labels_json(), "counter"],
            )?;
            count += 1;
        }
        drop(counters);

        // Snapshot gauges
        let gauges = self.gauges.read();
        for (key, gauge) in gauges.iter() {
            db.execute(
                "INSERT INTO metrics_snapshots (timestamp, name, value, labels, metric_type)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![now, key.name, gauge.get(), key.labels_json(), "gauge"],
            )?;
            count += 1;
        }
        drop(gauges);

        // Snapshot histogram summaries (persist p50 as the value)
        let histograms = self.histograms.read();
        for (key, histogram) in histograms.iter() {
            let summary = histogram.summary();
            db.execute(
                "INSERT INTO metrics_snapshots (timestamp, name, value, labels, metric_type)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![now, key.name, summary.p50, key.labels_json(), "histogram"],
            )?;
            count += 1;
        }

        Ok(count)
    }

    /// Query historical metric snapshots.
    pub fn query(&self, q: &MetricsQuery) -> Result<Vec<MetricsSnapshot>, rusqlite::Error> {
        let db = self.db.lock();
        let mut sql = String::from(
            "SELECT id, timestamp, name, value, labels, metric_type FROM metrics_snapshots WHERE 1=1",
        );
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(name) = &q.name {
            sql.push_str(&format!(" AND name = ?{}", params.len() + 1));
            params.push(Box::new(name.clone()));
        }
        if let Some(since) = &q.since {
            sql.push_str(&format!(" AND timestamp >= ?{}", params.len() + 1));
            params.push(Box::new(since.clone()));
        }

        sql.push_str(" ORDER BY id DESC");
        let limit = q.limit.unwrap_or(100);
        sql.push_str(&format!(" LIMIT {limit}"));

        let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let mut stmt = db.prepare(&sql)?;
        let rows = stmt.query_map(param_refs.as_slice(), |row| {
            let mt_str: String = row.get(5)?;
            let metric_type = match mt_str.as_str() {
                "counter" => MetricType::Counter,
                "gauge" => MetricType::Gauge,
                "histogram" => MetricType::Histogram,
                _ => MetricType::Counter,
            };
            Ok(MetricsSnapshot {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                name: row.get(2)?,
                value: row.get(3)?,
                labels: row.get(4)?,
                metric_type,
            })
        })?;

        rows.collect()
    }

    /// Prune snapshots older than retention_days.
    pub fn prune(&self, retention_days: u32) -> Result<usize, rusqlite::Error> {
        let db = self.db.lock();
        let cutoff = Utc::now()
            .checked_sub_signed(chrono::Duration::days(retention_days as i64))
            .unwrap_or_else(Utc::now)
            .to_rfc3339();
        db.execute(
            "DELETE FROM metrics_snapshots WHERE timestamp < ?1",
            rusqlite::params![cutoff],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_db() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron-test-metrics-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("test-metrics.db")
    }

    #[test]
    fn counter_basic() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        recorder.counter_inc("requests.total", &[("method", "GET")], 1);
        recorder.counter_inc("requests.total", &[("method", "GET")], 1);
        recorder.counter_inc("requests.total", &[("method", "POST")], 1);

        assert_eq!(recorder.counter_get("requests.total", &[("method", "GET")]), 2);
        assert_eq!(recorder.counter_get("requests.total", &[("method", "POST")]), 1);
        assert_eq!(recorder.counter_get("requests.total", &[("method", "PUT")]), 0);
    }

    #[test]
    fn gauge_set_and_increment() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        recorder.gauge_set("connections.active", &[], 10.0);
        assert_eq!(recorder.gauge_get("connections.active", &[]), 10.0);

        recorder.gauge_inc("connections.active", &[], 5.0);
        assert_eq!(recorder.gauge_get("connections.active", &[]), 15.0);

        recorder.gauge_inc("connections.active", &[], -3.0);
        assert_eq!(recorder.gauge_get("connections.active", &[]), 12.0);
    }

    #[test]
    fn histogram_observations() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        let labels = &[("tool", "Read")];

        for v in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0] {
            recorder.histogram_observe("tool.duration_ms", labels, v);
        }

        let summary = recorder.histogram_summary("tool.duration_ms", labels);
        assert_eq!(summary.count, 10);
        assert_eq!(summary.sum, 550.0);
        assert!(summary.p50 >= 50.0 && summary.p50 <= 60.0);
        assert!(summary.p95 >= 90.0);
    }

    #[test]
    fn histogram_empty() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        let summary = recorder.histogram_summary("nonexistent", &[]);
        assert_eq!(summary.count, 0);
        assert_eq!(summary.sum, 0.0);
    }

    #[test]
    fn snapshot_persists_to_sqlite() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        recorder.counter_inc("llm.requests.total", &[("provider", "anthropic")], 42);
        recorder.gauge_set("ws.connections.active", &[], 5.0);
        recorder.histogram_observe("llm.request.duration_ms", &[], 123.0);

        let count = recorder.snapshot().unwrap();
        assert_eq!(count, 3);

        let results = recorder
            .query(&MetricsQuery {
                name: Some("llm.requests.total".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].value, 42.0);
        assert_eq!(results[0].metric_type, MetricType::Counter);
        assert!(results[0].labels.is_some());
    }

    #[test]
    fn query_with_since_filter() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        recorder.counter_inc("test.counter", &[], 1);
        recorder.snapshot().unwrap();

        // Query with a future timestamp should return nothing
        let results = recorder
            .query(&MetricsQuery {
                since: Some("2099-01-01T00:00:00Z".into()),
                ..Default::default()
            })
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn prune_old_snapshots() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        recorder.counter_inc("test.counter", &[], 1);
        recorder.snapshot().unwrap();

        // Pruning with 0 days retention should remove all
        let removed = recorder.prune(0).unwrap();
        assert_eq!(removed, 1);

        let results = recorder
            .query(&MetricsQuery::default())
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn label_ordering_independent() {
        let recorder = MetricsRecorder::new(&temp_db()).unwrap();
        // Labels in different order should map to the same metric
        recorder.counter_inc("test", &[("a", "1"), ("b", "2")], 1);
        recorder.counter_inc("test", &[("b", "2"), ("a", "1")], 1);

        assert_eq!(recorder.counter_get("test", &[("a", "1"), ("b", "2")]), 2);
        assert_eq!(recorder.counter_get("test", &[("b", "2"), ("a", "1")]), 2);
    }

    #[test]
    fn metric_key_labels_json() {
        let key = MetricKey::new("test", &[("provider", "anthropic"), ("model", "opus")]);
        let json = key.labels_json().unwrap();
        let parsed: HashMap<String, String> = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["provider"], "anthropic");
        assert_eq!(parsed["model"], "opus");

        let empty = MetricKey::new("test", &[]);
        assert!(empty.labels_json().is_none());
    }

    #[test]
    fn metrics_snapshot_serde() {
        let snapshot = MetricsSnapshot {
            id: 1,
            timestamp: "2026-02-14T12:00:00Z".into(),
            name: "llm.requests.total".into(),
            value: 42.0,
            labels: Some(r#"{"provider":"anthropic"}"#.into()),
            metric_type: MetricType::Counter,
        };
        let json = serde_json::to_string(&snapshot).unwrap();
        let parsed: MetricsSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.name, "llm.requests.total");
        assert_eq!(parsed.metric_type, MetricType::Counter);
    }

    #[test]
    fn concurrent_counter_increments() {
        use std::sync::Arc;
        use std::thread;

        let recorder = Arc::new(MetricsRecorder::new(&temp_db()).unwrap());
        let mut handles = vec![];

        for _ in 0..10 {
            let r = recorder.clone();
            handles.push(thread::spawn(move || {
                for _ in 0..1000 {
                    r.counter_inc("concurrent.test", &[], 1);
                }
            }));
        }

        for h in handles {
            h.join().unwrap();
        }

        assert_eq!(recorder.counter_get("concurrent.test", &[]), 10_000);
    }
}
