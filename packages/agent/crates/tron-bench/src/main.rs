//! Benchmark harness for key Tron gateway scenarios.
//!
//! Produces JSON latency/memory reports for:
//! - prompt text only
//! - prompt with tools
//! - concurrent sessions
//! - session creation
//! - WebSocket session fanout

#![deny(unsafe_code)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use anyhow::{Context, Result};
use clap::Parser;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sysinfo::{ProcessesToUpdate, System};
use tron_events::{AppendOptions, ConnectionConfig, EventStore, EventType};
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_server::rpc::types::RpcEvent;
use tron_server::websocket::broadcast::BroadcastManager;
use tron_server::websocket::connection::ClientConnection;

#[derive(Debug, Parser)]
#[command(
    name = "tron-bench",
    about = "Benchmark runner for agent server hot paths"
)]
struct Args {
    /// Scenario to run: `prompt_text_only`, `prompt_with_tools`,
    /// `concurrent_sessions`, `session_create`, `ws_session_fanout`, `gate`, `all`.
    #[arg(long, default_value = "all")]
    scenario: String,

    /// Iteration count (turns per scenario; for concurrent scenario, turns per session).
    #[arg(long, default_value_t = 100)]
    iterations: usize,

    /// Number of parallel sessions for concurrent scenario.
    #[arg(long, default_value_t = 16)]
    concurrency: usize,

    /// Optional output path for JSON report.
    #[arg(long)]
    output: Option<PathBuf>,

    /// Optional baseline report for comparison/gating.
    #[arg(long)]
    baseline: Option<PathBuf>,

    /// Enforce acceptance gates against baseline.
    #[arg(long, default_value_t = false)]
    enforce_gates: bool,

    /// Maximum allowed p95 latency regression percentage versus baseline.
    #[arg(long, default_value_t = 5.0)]
    max_p95_regression_pct: f64,

    /// Maximum allowed mean latency regression percentage versus baseline.
    #[arg(long, default_value_t = 10.0)]
    max_mean_regression_pct: f64,

    /// Maximum allowed peak-memory regression percentage versus baseline.
    #[arg(long, default_value_t = 10.0)]
    max_peak_memory_regression_pct: f64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Report {
    generated_at: String,
    environment: ReportEnvironment,
    config: ReportConfig,
    scenarios: Vec<ScenarioResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct ReportEnvironment {
    os: String,
    arch: String,
    cpu_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct ReportConfig {
    requested_scenario: String,
    iterations: usize,
    concurrency: usize,
}

#[derive(Debug, Serialize, Deserialize)]
struct ScenarioResult {
    name: String,
    iterations: usize,
    latency_ms: LatencyStats,
    peak_memory_bytes: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct LatencyStats {
    p50: f64,
    p95: f64,
    mean: f64,
    min: f64,
    max: f64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    validate_gate_args(&args)?;
    let names = scenario_names(&args.scenario)?;
    let mut results = Vec::with_capacity(names.len());

    for name in names {
        let result = match name.as_str() {
            "prompt_text_only" => run_prompt_text_only(args.iterations)?,
            "prompt_with_tools" => run_prompt_with_tools(args.iterations)?,
            "concurrent_sessions" => run_concurrent_sessions(args.iterations, args.concurrency)?,
            "session_create" => run_session_create(args.iterations)?,
            "ws_session_fanout" => run_ws_session_fanout(args.iterations, args.concurrency)?,
            _ => unreachable!("validated scenario name"),
        };
        results.push(result);
    }

    let report = Report {
        generated_at: chrono::Utc::now().to_rfc3339(),
        environment: current_environment(),
        config: ReportConfig {
            requested_scenario: args.scenario.clone(),
            iterations: args.iterations,
            concurrency: args.concurrency,
        },
        scenarios: results,
    };

    if let Some(ref baseline_path) = args.baseline {
        let baseline = load_report(baseline_path)?;
        let thresholds = GateThresholds {
            p95_regression_limit_pct: args.max_p95_regression_pct,
            mean_regression_limit_pct: args.max_mean_regression_pct,
            peak_memory_regression_limit_pct: args.max_peak_memory_regression_pct,
        };
        let gate = evaluate_gates(&baseline, &report, thresholds);
        println!(
            "Benchmark gate summary: comparable {}, incompatible {}, missing baseline {}, failed {}, worst p95 regression {:.2}%, worst mean regression {:.2}%, worst peak memory regression {:.2}%",
            gate.comparable_scenarios,
            gate.incompatibilities.len(),
            gate.missing_baseline_scenarios.len(),
            gate.failed_scenarios.len(),
            gate.worst_p95_regression_pct,
            gate.worst_mean_regression_pct,
            gate.worst_peak_memory_regression_pct,
        );
        for incompatibility in &gate.incompatibilities {
            println!("  incompatible baseline: {incompatibility}");
        }
        for missing in &gate.missing_baseline_scenarios {
            println!("  missing baseline scenario: {missing}");
        }
        for failure in &gate.failed_scenarios {
            println!(
                "  regression {}: p95 +{:.2}% (limit {:.2}%), mean +{:.2}% (limit {:.2}%), peak memory +{:.2}% (limit {:.2}%)",
                failure.name,
                failure.p95_regression_pct,
                thresholds.p95_regression_limit_pct,
                failure.mean_regression_pct,
                thresholds.mean_regression_limit_pct,
                failure.peak_memory_regression_pct,
                thresholds.peak_memory_regression_limit_pct,
            );
        }
        if args.enforce_gates && !gate.passed {
            anyhow::bail!("benchmark regression gates failed");
        }
    }

    let encoded = serde_json::to_string_pretty(&report)?;

    if let Some(path) = args.output {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create benchmark output dir: {}",
                    parent.display()
                )
            })?;
        }
        std::fs::write(&path, &encoded)
            .with_context(|| format!("failed to write benchmark report: {}", path.display()))?;
        println!("{}", path.display());
    } else {
        println!("{encoded}");
    }

    Ok(())
}

#[derive(Debug, Default)]
struct GateEvaluation {
    comparable_scenarios: usize,
    incompatibilities: Vec<String>,
    missing_baseline_scenarios: Vec<String>,
    failed_scenarios: Vec<ScenarioRegression>,
    worst_p95_regression_pct: f64,
    worst_mean_regression_pct: f64,
    worst_peak_memory_regression_pct: f64,
    passed: bool,
}

#[derive(Debug, Clone, Copy)]
#[allow(clippy::struct_field_names)]
struct GateThresholds {
    p95_regression_limit_pct: f64,
    mean_regression_limit_pct: f64,
    peak_memory_regression_limit_pct: f64,
}

#[derive(Debug)]
struct ScenarioRegression {
    name: String,
    p95_regression_pct: f64,
    mean_regression_pct: f64,
    peak_memory_regression_pct: f64,
}

fn scenario_names(name: &str) -> Result<Vec<String>> {
    match name {
        "all" => Ok(vec![
            "prompt_text_only".to_string(),
            "prompt_with_tools".to_string(),
            "concurrent_sessions".to_string(),
            "session_create".to_string(),
            "ws_session_fanout".to_string(),
        ]),
        "gate" => Ok(vec![
            "prompt_text_only".to_string(),
            "prompt_with_tools".to_string(),
            "session_create".to_string(),
            "ws_session_fanout".to_string(),
        ]),
        "prompt_text_only"
        | "prompt_with_tools"
        | "concurrent_sessions"
        | "session_create"
        | "ws_session_fanout" => Ok(vec![name.to_string()]),
        other => anyhow::bail!("unknown scenario: {other}"),
    }
}

fn validate_gate_args(args: &Args) -> Result<()> {
    if args.enforce_gates && args.baseline.is_none() {
        anyhow::bail!("--enforce-gates requires --baseline");
    }
    Ok(())
}

fn current_environment() -> ReportEnvironment {
    ReportEnvironment {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        cpu_count: std::thread::available_parallelism().map_or(1, usize::from),
    }
}

fn setup_store() -> Result<(Arc<EventStore>, tempfile::TempDir)> {
    let dir = tempfile::tempdir().context("failed to create temp dir for benchmark db")?;
    let db = dir.path().join("bench.db");
    let path = db.to_string_lossy().to_string();
    let pool = tron_events::new_file(&path, &ConnectionConfig::default())
        .context("failed to open benchmark sqlite database")?;
    {
        let conn = pool
            .get()
            .context("failed to get benchmark db connection")?;
        let _ = tron_events::run_migrations(&conn).context("failed to run benchmark migrations")?;
    }
    Ok((Arc::new(EventStore::new(pool)), dir))
}

fn run_prompt_text_only(iterations: usize) -> Result<ScenarioResult> {
    let (store, _tmp) = setup_store()?;
    let session = store.create_session(
        "claude-sonnet-4-20250514",
        "/tmp/bench-text",
        Some("text-only"),
        None,
        None,
    )?;
    let session_id = session.session.id;

    let peak_memory = AtomicU64::new(current_process_memory_bytes());
    let mut latencies = Vec::with_capacity(iterations);
    for i in 0..iterations {
        let start = Instant::now();
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": format!("hello {i}")}]
                },
            }),
            parent_id: None,
        })?;
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "ok"}]
                },
                "tokenUsage": {
                    "inputTokens": 32,
                    "outputTokens": 64
                }
            }),
            parent_id: None,
        })?;
        let _ = store.get_state_at_head(&session_id)?;
        latencies.push(start.elapsed().as_secs_f64() * 1000.0);
        sample_peak_memory(&peak_memory);
    }

    Ok(ScenarioResult {
        name: "prompt_text_only".to_string(),
        iterations,
        latency_ms: summarize_latencies(&latencies),
        peak_memory_bytes: peak_memory.load(Ordering::Relaxed),
    })
}

fn run_prompt_with_tools(iterations: usize) -> Result<ScenarioResult> {
    let (store, _tmp) = setup_store()?;
    let session = store.create_session(
        "claude-sonnet-4-20250514",
        "/tmp/bench-tools",
        Some("with-tools"),
        None,
        None,
    )?;
    let session_id = session.session.id;

    let peak_memory = AtomicU64::new(current_process_memory_bytes());
    let mut latencies = Vec::with_capacity(iterations);
    for i in 0..iterations {
        let call_id = format!("tool-call-{i}");
        let start = Instant::now();
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": "read file"}]
                },
            }),
            parent_id: None,
        })?;
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": call_id,
                        "name": "Read",
                        "arguments": {"file": "src/lib.rs"}
                    }]
                }
            }),
            parent_id: None,
        })?;
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::ToolResult,
            payload: json!({
                "toolCallId": format!("tool-call-{i}"),
                "content": "file contents",
            }),
            parent_id: None,
        })?;
        let _ = store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "done"}]
                },
                "tokenUsage": {
                    "inputTokens": 80,
                    "outputTokens": 120
                }
            }),
            parent_id: None,
        })?;
        let _ = store.get_state_at_head(&session_id)?;
        latencies.push(start.elapsed().as_secs_f64() * 1000.0);
        sample_peak_memory(&peak_memory);
    }

    Ok(ScenarioResult {
        name: "prompt_with_tools".to_string(),
        iterations,
        latency_ms: summarize_latencies(&latencies),
        peak_memory_bytes: peak_memory.load(Ordering::Relaxed),
    })
}

fn run_concurrent_sessions(iterations: usize, concurrency: usize) -> Result<ScenarioResult> {
    let (store, _tmp) = setup_store()?;
    let peak_memory = Arc::new(AtomicU64::new(current_process_memory_bytes()));
    let mut handles = Vec::with_capacity(concurrency);

    for worker in 0..concurrency {
        let store = Arc::clone(&store);
        let peak = Arc::clone(&peak_memory);
        handles.push(std::thread::spawn(move || -> Result<Vec<f64>> {
            let session = store.create_session(
                "claude-sonnet-4-20250514",
                &format!("/tmp/bench-concurrent-{worker}"),
                Some("concurrent"),
                None,
                None,
            )?;
            let session_id = session.session.id;
            let mut latencies = Vec::with_capacity(iterations);
            for turn in 0..iterations {
                let start = Instant::now();
                let _ = store.append(&AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::MessageUser,
                    payload: json!({
                        "message": {
                            "role": "user",
                            "content": [{"type": "text", "text": format!("parallel-{turn}")}]
                        }
                    }),
                    parent_id: None,
                })?;
                let _ = store.append(&AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::MessageAssistant,
                    payload: json!({
                        "message": {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "ok"}]
                        },
                        "tokenUsage": {
                            "inputTokens": 24,
                            "outputTokens": 48
                        }
                    }),
                    parent_id: None,
                })?;
                let _ = store.get_state_at_head(&session_id)?;
                latencies.push(start.elapsed().as_secs_f64() * 1000.0);
                sample_peak_memory(&peak);
            }
            Ok(latencies)
        }));
    }

    let mut all_latencies = Vec::with_capacity(concurrency * iterations);
    for handle in handles {
        let worker_latencies = handle
            .join()
            .map_err(|_| anyhow::anyhow!("concurrent bench thread panicked"))??;
        all_latencies.extend(worker_latencies);
    }

    Ok(ScenarioResult {
        name: "concurrent_sessions".to_string(),
        iterations: iterations * concurrency,
        latency_ms: summarize_latencies(&all_latencies),
        peak_memory_bytes: peak_memory.load(Ordering::Relaxed),
    })
}

fn run_session_create(iterations: usize) -> Result<ScenarioResult> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("failed to build tokio runtime for session_create benchmark")?;

    runtime.block_on(async move {
        let (store, _tmp) = setup_store()?;
        let manager = SessionManager::new(store);
        let peak_memory = AtomicU64::new(current_process_memory_bytes());
        let mut latencies = Vec::with_capacity(iterations);

        for i in 0..iterations {
            let working_dir = format!("/tmp/bench-session-create-{i}");
            let start = Instant::now();
            let session_id =
                manager.create_session("claude-sonnet-4-20250514", &working_dir, Some("bench"))?;
            latencies.push(start.elapsed().as_secs_f64() * 1000.0);
            sample_peak_memory(&peak_memory);
            manager.delete_session(&session_id)?;
        }

        Ok(ScenarioResult {
            name: "session_create".to_string(),
            iterations,
            latency_ms: summarize_latencies(&latencies),
            peak_memory_bytes: peak_memory.load(Ordering::Relaxed),
        })
    })
}

fn run_ws_session_fanout(iterations: usize, concurrency: usize) -> Result<ScenarioResult> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("failed to build tokio runtime for ws fanout benchmark")?;

    runtime.block_on(async move {
        let broadcast = Arc::new(BroadcastManager::new());
        let mut receivers = Vec::with_capacity(concurrency);
        for index in 0..concurrency {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            let connection = Arc::new(ClientConnection::new(format!("bench-{index}"), tx));
            connection.bind_session("fanout");
            broadcast.add(connection).await;
            receivers.push(rx);
        }

        let peak_memory = AtomicU64::new(current_process_memory_bytes());
        let mut latencies = Vec::with_capacity(iterations);
        for turn in 0..iterations {
            let event = RpcEvent {
                event_type: "bench.fanout".into(),
                session_id: Some("fanout".into()),
                timestamp: chrono::Utc::now().to_rfc3339(),
                data: Some(json!({
                    "turn": turn,
                    "payload": "ok",
                })),
                run_id: None,
            };

            let start = Instant::now();
            broadcast.broadcast_to_session("fanout", &event).await;
            for rx in &mut receivers {
                let message = rx
                    .recv()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("fanout receiver unexpectedly closed"))?;
                drop(message);
                while rx.try_recv().is_ok() {}
            }
            latencies.push(start.elapsed().as_secs_f64() * 1000.0);
            sample_peak_memory(&peak_memory);
        }

        Ok(ScenarioResult {
            name: "ws_session_fanout".to_string(),
            iterations,
            latency_ms: summarize_latencies(&latencies),
            peak_memory_bytes: peak_memory.load(Ordering::Relaxed),
        })
    })
}

fn summarize_latencies(latencies_ms: &[f64]) -> LatencyStats {
    if latencies_ms.is_empty() {
        return LatencyStats {
            p50: 0.0,
            p95: 0.0,
            mean: 0.0,
            min: 0.0,
            max: 0.0,
        };
    }

    let mut sorted = latencies_ms.to_vec();
    sorted.sort_by(f64::total_cmp);
    let len = sorted.len();
    #[allow(clippy::cast_precision_loss)]
    let mean = sorted.iter().sum::<f64>() / len as f64;
    let p50_idx = percentile_index(len, 0.50);
    let p95_idx = percentile_index(len, 0.95);

    LatencyStats {
        p50: sorted[p50_idx],
        p95: sorted[p95_idx],
        mean,
        min: sorted[0],
        max: sorted[len - 1],
    }
}

fn percentile_index(len: usize, percentile: f64) -> usize {
    if len <= 1 {
        return 0;
    }
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let rank = ((len - 1) as f64 * percentile).round() as usize;
    rank.min(len - 1)
}

fn current_process_memory_bytes() -> u64 {
    let mut system = System::new();
    let Ok(pid) = sysinfo::get_current_pid() else {
        return 0;
    };
    let _ = system.refresh_processes(ProcessesToUpdate::Some(&[pid]), false);
    system.process(pid).map_or(0, sysinfo::Process::memory)
}

fn sample_peak_memory(peak: &AtomicU64) {
    let current = current_process_memory_bytes();
    let mut observed = peak.load(Ordering::Relaxed);
    while current > observed {
        match peak.compare_exchange_weak(observed, current, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => break,
            Err(next) => observed = next,
        }
    }
}

fn load_report(path: &PathBuf) -> Result<Report> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read baseline report: {}", path.display()))?;
    let report: Report = serde_json::from_str(&content)
        .with_context(|| format!("failed to parse baseline report: {}", path.display()))?;
    Ok(report)
}

fn evaluate_gates(
    baseline: &Report,
    current: &Report,
    thresholds: GateThresholds,
) -> GateEvaluation {
    let mut evaluation = GateEvaluation {
        incompatibilities: report_incompatibilities(baseline, current),
        ..GateEvaluation::default()
    };
    if !evaluation.incompatibilities.is_empty() {
        return evaluation;
    }

    let baseline_by_name: std::collections::HashMap<&str, &ScenarioResult> = baseline
        .scenarios
        .iter()
        .map(|scenario| (scenario.name.as_str(), scenario))
        .collect();

    for current_scenario in &current.scenarios {
        let Some(base_scenario) = baseline_by_name.get(current_scenario.name.as_str()) else {
            evaluation
                .missing_baseline_scenarios
                .push(current_scenario.name.clone());
            continue;
        };
        evaluation.comparable_scenarios += 1;

        let p95_regression_pct = latency_regression_pct(
            base_scenario.latency_ms.p95,
            current_scenario.latency_ms.p95,
        );
        let mean_regression_pct = latency_regression_pct(
            base_scenario.latency_ms.mean,
            current_scenario.latency_ms.mean,
        );
        let peak_memory_regression_pct = memory_regression_pct(
            #[allow(clippy::cast_precision_loss)]
            {
                base_scenario.peak_memory_bytes as f64
            },
            #[allow(clippy::cast_precision_loss)]
            {
                current_scenario.peak_memory_bytes as f64
            },
        );
        if p95_regression_pct > evaluation.worst_p95_regression_pct {
            evaluation.worst_p95_regression_pct = p95_regression_pct;
        }
        if mean_regression_pct > evaluation.worst_mean_regression_pct {
            evaluation.worst_mean_regression_pct = mean_regression_pct;
        }
        if peak_memory_regression_pct > evaluation.worst_peak_memory_regression_pct {
            evaluation.worst_peak_memory_regression_pct = peak_memory_regression_pct;
        }

        if p95_regression_pct > thresholds.p95_regression_limit_pct
            || mean_regression_pct > thresholds.mean_regression_limit_pct
            || peak_memory_regression_pct > thresholds.peak_memory_regression_limit_pct
        {
            evaluation.failed_scenarios.push(ScenarioRegression {
                name: current_scenario.name.clone(),
                p95_regression_pct,
                mean_regression_pct,
                peak_memory_regression_pct,
            });
        }
    }

    evaluation.passed = evaluation.comparable_scenarios > 0
        && evaluation.incompatibilities.is_empty()
        && evaluation.missing_baseline_scenarios.is_empty()
        && evaluation.failed_scenarios.is_empty();
    evaluation
}

fn report_incompatibilities(baseline: &Report, current: &Report) -> Vec<String> {
    let mut mismatches = Vec::new();

    if baseline.environment != current.environment {
        mismatches.push(format!(
            "environment mismatch: baseline {}-{} cpu_count {}, current {}-{} cpu_count {}",
            baseline.environment.os,
            baseline.environment.arch,
            baseline.environment.cpu_count,
            current.environment.os,
            current.environment.arch,
            current.environment.cpu_count,
        ));
    }

    if baseline.config != current.config {
        mismatches.push(format!(
            "config mismatch: baseline scenario={} iterations={} concurrency={}, current scenario={} iterations={} concurrency={}",
            baseline.config.requested_scenario,
            baseline.config.iterations,
            baseline.config.concurrency,
            current.config.requested_scenario,
            current.config.iterations,
            current.config.concurrency,
        ));
    }

    mismatches
}

fn latency_regression_pct(baseline: f64, current: f64) -> f64 {
    regression_pct_with_floor(baseline, current, 5.0)
}

fn memory_regression_pct(baseline: f64, current: f64) -> f64 {
    regression_pct_with_floor(baseline, current, 0.0)
}

fn regression_pct_with_floor(baseline: f64, current: f64, floor: f64) -> f64 {
    if baseline <= 0.0 {
        return 0.0;
    }
    ((current - baseline) / baseline.max(floor)).max(0.0) * 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thresholds() -> GateThresholds {
        GateThresholds {
            p95_regression_limit_pct: 5.0,
            mean_regression_limit_pct: 10.0,
            peak_memory_regression_limit_pct: 10.0,
        }
    }

    fn scenario(name: &str, p95: f64, mean: f64, peak_memory_bytes: u64) -> ScenarioResult {
        ScenarioResult {
            name: name.into(),
            iterations: 1,
            latency_ms: LatencyStats {
                p50: p95,
                p95,
                mean,
                min: p95,
                max: p95,
            },
            peak_memory_bytes,
        }
    }

    fn report(scenarios: Vec<ScenarioResult>) -> Report {
        Report {
            generated_at: "2026-01-01T00:00:00Z".into(),
            environment: ReportEnvironment {
                os: "macos".into(),
                arch: "aarch64".into(),
                cpu_count: 12,
            },
            config: ReportConfig {
                requested_scenario: "all".into(),
                iterations: 20,
                concurrency: 8,
            },
            scenarios,
        }
    }

    #[test]
    fn scenario_names_all_includes_new_scenarios() {
        let names = scenario_names("all").unwrap();
        assert!(names.contains(&"session_create".to_string()));
        assert!(names.contains(&"ws_session_fanout".to_string()));
    }

    #[test]
    fn scenario_names_gate_uses_stable_regression_subset() {
        let names = scenario_names("gate").unwrap();
        assert_eq!(
            names,
            vec![
                "prompt_text_only".to_string(),
                "prompt_with_tools".to_string(),
                "session_create".to_string(),
                "ws_session_fanout".to_string(),
            ]
        );
    }

    #[test]
    fn evaluate_gates_counts_only_comparable_scenarios() {
        let baseline = report(vec![scenario("prompt_text_only", 10.0, 10.0, 100)]);
        let current = report(vec![
            scenario("prompt_text_only", 5.0, 5.0, 50),
            scenario("ws_session_fanout", 1.0, 1.0, 10),
        ]);

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert_eq!(evaluation.comparable_scenarios, 1);
        assert_eq!(
            evaluation.missing_baseline_scenarios,
            vec!["ws_session_fanout".to_string()]
        );
        assert!(!evaluation.passed);
    }

    #[test]
    fn evaluate_gates_fails_when_regression_exceeds_threshold() {
        let baseline = report(vec![scenario("prompt_text_only", 100.0, 100.0, 100)]);
        let current = report(vec![scenario("prompt_text_only", 106.0, 112.0, 111)]);

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert!(!evaluation.passed);
        assert_eq!(evaluation.failed_scenarios.len(), 1);
        assert_eq!(evaluation.failed_scenarios[0].name, "prompt_text_only");
        assert!(evaluation.failed_scenarios[0].p95_regression_pct > 5.0);
    }

    #[test]
    fn evaluate_gates_passes_when_within_thresholds() {
        let baseline = report(vec![
            scenario("prompt_text_only", 100.0, 100.0, 100),
            scenario("ws_session_fanout", 20.0, 20.0, 200),
        ]);
        let current = report(vec![
            scenario("prompt_text_only", 104.0, 108.0, 109),
            scenario("ws_session_fanout", 20.5, 21.0, 210),
        ]);

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert!(evaluation.passed);
        assert!(evaluation.failed_scenarios.is_empty());
        assert!(evaluation.missing_baseline_scenarios.is_empty());
    }

    #[test]
    fn evaluate_gates_ignores_tiny_latency_percentage_noise() {
        let baseline = report(vec![scenario("ws_session_fanout", 0.004, 0.003, 100)]);
        let current = report(vec![scenario("ws_session_fanout", 0.006, 0.004, 100)]);

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert!(evaluation.passed);
        assert!(evaluation.failed_scenarios.is_empty());
    }

    #[test]
    fn evaluate_gates_fails_when_environment_differs() {
        let baseline = report(vec![scenario("prompt_text_only", 10.0, 10.0, 100)]);
        let mut current = report(vec![scenario("prompt_text_only", 9.0, 9.0, 95)]);
        current.environment.cpu_count = 8;

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert!(!evaluation.passed);
        assert_eq!(evaluation.comparable_scenarios, 0);
        assert_eq!(evaluation.incompatibilities.len(), 1);
        assert!(evaluation.incompatibilities[0].contains("environment mismatch"));
    }

    #[test]
    fn evaluate_gates_fails_when_config_differs() {
        let baseline = report(vec![scenario("prompt_text_only", 10.0, 10.0, 100)]);
        let mut current = report(vec![scenario("prompt_text_only", 9.0, 9.0, 95)]);
        current.config.iterations = 40;

        let evaluation = evaluate_gates(&baseline, &current, thresholds());
        assert!(!evaluation.passed);
        assert_eq!(evaluation.comparable_scenarios, 0);
        assert_eq!(evaluation.incompatibilities.len(), 1);
        assert!(evaluation.incompatibilities[0].contains("config mismatch"));
    }

    #[test]
    fn validate_gate_args_requires_baseline_when_enforcing() {
        let args = Args {
            scenario: "all".into(),
            iterations: 1,
            concurrency: 1,
            output: None,
            baseline: None,
            enforce_gates: true,
            max_p95_regression_pct: 5.0,
            max_mean_regression_pct: 10.0,
            max_peak_memory_regression_pct: 10.0,
        };

        let error = validate_gate_args(&args).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("--enforce-gates requires --baseline")
        );
    }
}
