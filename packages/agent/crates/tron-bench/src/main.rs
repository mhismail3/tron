//! Benchmark harness for key Tron gateway scenarios.
//!
//! Produces JSON latency/memory reports for:
//! - prompt text only
//! - prompt with tools
//! - concurrent sessions

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

#[derive(Debug, Parser)]
#[command(
    name = "tron-bench",
    about = "Benchmark runner for agent server hot paths"
)]
struct Args {
    /// Scenario to run: `prompt_text_only`, `prompt_with_tools`, `concurrent_sessions`, `all`.
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
}

#[derive(Debug, Serialize, Deserialize)]
struct Report {
    generated_at: String,
    scenarios: Vec<ScenarioResult>,
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
    let names = scenario_names(&args.scenario)?;
    let mut results = Vec::with_capacity(names.len());

    for name in names {
        let result = match name.as_str() {
            "prompt_text_only" => run_prompt_text_only(args.iterations)?,
            "prompt_with_tools" => run_prompt_with_tools(args.iterations)?,
            "concurrent_sessions" => run_concurrent_sessions(args.iterations, args.concurrency)?,
            _ => unreachable!("validated scenario name"),
        };
        results.push(result);
    }

    let report = Report {
        generated_at: chrono::Utc::now().to_rfc3339(),
        scenarios: results,
    };

    if let Some(ref baseline_path) = args.baseline {
        let baseline = load_report(baseline_path)?;
        let gate = evaluate_gates(&baseline, &report);
        println!(
            "Benchmark gate summary: p95>=30% improved in {}/3, memory>=30% reduced in {}/3, worst p95 regression {:.2}%",
            gate.p95_improved_scenarios,
            gate.memory_improved_scenarios,
            gate.worst_p95_regression_pct
        );
        if args.enforce_gates && !gate.passed {
            anyhow::bail!(
                "benchmark gates failed: requires >=2 scenarios with >=30% p95 improvement, >=2 scenarios with >=30% memory reduction, and no p95 regression >5%"
            );
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
    p95_improved_scenarios: usize,
    memory_improved_scenarios: usize,
    worst_p95_regression_pct: f64,
    passed: bool,
}

fn scenario_names(name: &str) -> Result<Vec<String>> {
    match name {
        "all" => Ok(vec![
            "prompt_text_only".to_string(),
            "prompt_with_tools".to_string(),
            "concurrent_sessions".to_string(),
        ]),
        "prompt_text_only" | "prompt_with_tools" | "concurrent_sessions" => {
            Ok(vec![name.to_string()])
        }
        other => anyhow::bail!("unknown scenario: {other}"),
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

fn evaluate_gates(baseline: &Report, current: &Report) -> GateEvaluation {
    let mut evaluation = GateEvaluation::default();
    let baseline_by_name: std::collections::HashMap<&str, &ScenarioResult> = baseline
        .scenarios
        .iter()
        .map(|scenario| (scenario.name.as_str(), scenario))
        .collect();

    for current_scenario in &current.scenarios {
        let Some(base_scenario) = baseline_by_name.get(current_scenario.name.as_str()) else {
            continue;
        };

        let p95_improvement_pct = improvement_pct(
            base_scenario.latency_ms.p95,
            current_scenario.latency_ms.p95,
        );
        let memory_improvement_pct = improvement_pct(
            #[allow(clippy::cast_precision_loss)]
            {
                base_scenario.peak_memory_bytes as f64
            },
            #[allow(clippy::cast_precision_loss)]
            {
                current_scenario.peak_memory_bytes as f64
            },
        );
        let p95_regression_pct = regression_pct(
            base_scenario.latency_ms.p95,
            current_scenario.latency_ms.p95,
        );

        if p95_improvement_pct >= 30.0 {
            evaluation.p95_improved_scenarios += 1;
        }
        if memory_improvement_pct >= 30.0 {
            evaluation.memory_improved_scenarios += 1;
        }
        if p95_regression_pct > evaluation.worst_p95_regression_pct {
            evaluation.worst_p95_regression_pct = p95_regression_pct;
        }
    }

    evaluation.passed = evaluation.p95_improved_scenarios >= 2
        && evaluation.memory_improved_scenarios >= 2
        && evaluation.worst_p95_regression_pct <= 5.0;
    evaluation
}

fn improvement_pct(baseline: f64, current: f64) -> f64 {
    if baseline <= 0.0 {
        return 0.0;
    }
    ((baseline - current) / baseline) * 100.0
}

fn regression_pct(baseline: f64, current: f64) -> f64 {
    if baseline <= 0.0 {
        return 0.0;
    }
    ((current - baseline) / baseline).max(0.0) * 100.0
}
