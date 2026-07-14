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

fn assert_contains_in_order(name: &str, source: &str, needles: &[&str]) {
    let mut cursor = 0;
    for needle in needles {
        let relative = source[cursor..]
            .find(needle)
            .unwrap_or_else(|| panic!("{name} is missing ordered fragment `{needle}`"));
        cursor += relative + needle.len();
    }
}

fn task_cancel_is_joined(source: &str, owner: &str) -> bool {
    source.contains(&format!("{owner}?.cancel()"))
        && source.contains(&format!("await {owner}?.value"))
}

#[test]
fn ios_terminal_task_owners_cancel_and_await_exact_handles() {
    let manager =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift");
    assert_contains_in_order(
        "EventStoreManager terminal drain",
        &manager,
        &[
            "globalTask?.cancel()",
            "await globalTask?.value",
            "await refreshCoordinator.shutdown()",
            "loadTask?.cancel()",
            "await loadTask?.value",
        ],
    );
    assert!(manager.contains("if let shutdownTask"));
    assert!(manager.contains("await shutdownTask.value"));

    let refresh = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionRefreshService.swift",
    );
    assert_contains_in_order(
        "SessionRefreshService terminal drain",
        &refresh,
        &[
            "isStopped = true",
            "connectionManager?.cancelHook(label: Self.hookLabel)",
            "pendingDebounceTask?.cancel()",
            "acceptedInflightTask?.cancel()",
            "await pendingDebounceTask?.value",
            "await acceptedInflightTask?.value",
        ],
    );
    assert!(refresh.contains("guard !isStopped else { return }"));
    assert!(refresh.contains("if let shutdownTask"));
    assert!(refresh.contains("await shutdownTask.value"));

    let inventory = inventory_by_path();
    assert_eq!(inventory.len(), 158, "CSD inventory row total changed");
    assert_eq!(
        inventory
            .values()
            .filter(|row| row.scheduler_class == "test_fixture")
            .count(),
        27,
        "CSD test-fixture row total changed"
    );
    assert_eq!(
        inventory
            .values()
            .filter(|row| row.scheduler_class != "test_fixture")
            .count(),
        131,
        "CSD production row total changed"
    );
    for (scheduler_class, expected) in [
        ("debounce_or_coalescer", 10),
        ("main_actor_ui", 18),
        ("tracked_background_task", 15),
        ("external_callback_bridge", 9),
    ] {
        assert_eq!(
            inventory
                .values()
                .filter(|row| row.scheduler_class == scheduler_class)
                .count(),
            expected,
            "CSD `{scheduler_class}` row total changed"
        );
    }

    assert_eq!(
        inventory
            .get("packages/ios-app/Sources/App/Lifecycle/ProductionAppRoot.swift")
            .expect("ProductionAppRoot CSD row")
            .scheduler_class,
        "main_actor_ui"
    );
    assert_eq!(
        inventory
            .get("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift")
            .expect("EventStoreManager CSD row")
            .scheduler_class,
        "tracked_background_task"
    );
    assert_eq!(
        inventory
            .get("packages/ios-app/Sources/Engine/Persistence/Sync/SessionRefreshService.swift")
            .expect("SessionRefreshService CSD row")
            .scheduler_class,
        "debounce_or_coalescer"
    );
}

#[test]
fn cancellation_without_join_is_rejected_by_terminal_owner_detector() {
    assert!(!task_cancel_is_joined("ownedTask?.cancel()", "ownedTask"));
    assert!(task_cancel_is_joined(
        "ownedTask?.cancel(); await ownedTask?.value",
        "ownedTask"
    ));
}
