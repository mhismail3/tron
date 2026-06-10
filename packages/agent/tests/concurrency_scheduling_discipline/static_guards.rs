use super::support::{
    inventory_by_path, is_production_rust, is_production_swift, marker_paths, read_repo_file,
    text_has_any,
};

#[test]
fn production_rust_tokio_spawns_have_explicit_ownership() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| is_production_rust(path))
        .filter(|path| read_repo_file(path).contains("tokio::spawn"))
        .filter(|path| {
            let row = inventory
                .get(path)
                .unwrap_or_else(|| panic!("missing CSD inventory row for {path}"));
            let policy = format!(
                "{} {} {}",
                row.start_site, row.stop_or_cancel_site, row.test_evidence
            );
            !text_has_any(
                &policy,
                &[
                    "shutdown",
                    "cancellationtoken",
                    "cancel",
                    "abort",
                    "drain",
                    "join",
                    "await",
                    "scoped",
                    "request future",
                ],
            )
        })
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "production tokio::spawn sites need explicit CSD ownership:\n{}",
        missing.join("\n")
    );
}

#[test]
fn production_unbounded_mpsc_is_absent() {
    let offenders = marker_paths()
        .into_iter()
        .filter(|path| is_production_rust(path))
        .filter(|path| {
            let source = read_repo_file(path);
            source.contains("mpsc::unbounded_channel")
                || source.contains("UnboundedSender")
                || source.contains("UnboundedReceiver")
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production unbounded MPSC requires a narrow CSD exception and none are allowed now:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn production_swift_banned_scheduling_patterns_are_absent() {
    let offenders = marker_paths()
        .into_iter()
        .filter(|path| is_production_swift(path))
        .filter_map(|path| {
            let source = read_repo_file(&path);
            let hits = [
                "Task.detached",
                "DispatchQueue.global",
                "DispatchQueue.main.asyncAfter",
            ]
            .into_iter()
            .filter(|needle| source.contains(needle))
            .collect::<Vec<_>>();
            (!hits.is_empty()).then(|| format!("{path}: {}", hits.join(", ")))
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "production Swift banned scheduling patterns remain:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn production_swift_async_streams_have_bounded_policy_rows() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| is_production_swift(path))
        .filter(|path| read_repo_file(path).contains("AsyncStream"))
        .filter(|path| {
            let row = inventory
                .get(path)
                .unwrap_or_else(|| panic!("missing CSD inventory row for {path}"));
            let policy = format!(
                "{} {} {}",
                row.scheduler_class, row.backpressure_or_capacity, row.test_evidence
            );
            !text_has_any(
                &policy,
                &["bounded", "bufferingnewest", "cursor", "polling"],
            )
        })
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "production Swift AsyncStream surfaces need bounded buffering or cursor polling policy:\n{}",
        missing.join("\n")
    );
}

#[test]
fn swift_owner_classes_with_task_fields_expose_cancellation_paths() {
    let offenders = marker_paths()
        .into_iter()
        .filter(|path| is_production_swift(path))
        .filter(|path| {
            let source = read_repo_file(path);
            source.contains("Task<")
                && !text_has_any(
                    &source,
                    &[
                        "deinit",
                        "stop",
                        "reset",
                        "disconnect",
                        "cleanup",
                        "cancel",
                        "onDisappear",
                    ],
                )
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "Swift owner classes with stored Task fields need visible cancellation paths:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn production_sleep_and_timer_sites_have_inventory_policy() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| {
            let source = read_repo_file(path);
            source.contains("tokio::time::sleep")
                || source.contains("Task.sleep")
                || source.contains("thread::sleep")
                || source.contains("std::thread::sleep")
                || source.contains("Timer")
        })
        .filter(|path| {
            let row = inventory
                .get(path)
                .unwrap_or_else(|| panic!("missing CSD inventory row for {path}"));
            let policy = format!("{} {}", row.scheduler_class, row.timeout_or_deadline);
            !text_has_any(
                &policy,
                &[
                    "timer_loop",
                    "deadline",
                    "retry",
                    "heartbeat",
                    "debounce",
                    "batch",
                    "cadence",
                    "animation",
                    "layout",
                    "runtime-loop",
                    "ui work",
                ],
            )
        })
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "production sleep/timer sites need CSD deadline or cadence policy:\n{}",
        missing.join("\n")
    );
}

#[test]
fn external_worker_outbound_scheduling_is_bounded_in_source() {
    let source = read_repo_file("packages/agent/src/transport/runtime/external_workers.rs");
    for required in [
        "EXTERNAL_WORKER_OUTBOUND_CAPACITY",
        "mpsc::channel::<Message>(EXTERNAL_WORKER_OUTBOUND_CAPACITY)",
        "EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT",
        "WORKER_OUTBOUND_BACKPRESSURE_TIMEOUT",
        "worker_invocation_fails_when_outbound_queue_stays_full",
    ] {
        assert!(
            source.contains(required),
            "external worker bounded scheduling proof missing `{required}`"
        );
    }
}
