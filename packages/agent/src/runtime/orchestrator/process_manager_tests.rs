use super::*;
use crate::tools::traits::ProcessKind;
use std::time::Duration;

fn make_config(label: &str) -> ManagedProcessConfig {
    ManagedProcessConfig {
        label: label.into(),
        kind: ProcessKind::Shell,
        timeout_ms: None,
        blocking_timeout_ms: None,
        sandbox: false,
    }
}

fn make_blocking_config(label: &str) -> ManagedProcessConfig {
    ManagedProcessConfig {
        label: label.into(),
        kind: ProcessKind::Shell,
        timeout_ms: None,
        blocking_timeout_ms: Some(60_000),
        sandbox: false,
    }
}

fn boxed_immediate(
    output: &str,
    exit_code: i32,
) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
    let output = output.to_owned();
    Box::pin(async move {
        ManagedProcessResult {
            process_id: String::new(), // PM's task wrapper doesn't use this
            output,
            exit_code: Some(exit_code),
            duration_ms: 0,
            timed_out: false,
            cancelled: false,
            blob_id: None,
            user_cancelled: false,
        }
    })
}

fn boxed_delayed(
    ms: u64,
    output: &str,
) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
    let output = output.to_owned();
    Box::pin(async move {
        tokio::time::sleep(Duration::from_millis(ms)).await;
        ManagedProcessResult {
            process_id: String::new(),
            output,
            exit_code: Some(0),
            duration_ms: ms,
            timed_out: false,
            cancelled: false,
            blob_id: None,
            user_cancelled: false,
        }
    })
}

fn boxed_cancellable(
    cancel: CancellationToken,
) -> Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>> {
    Box::pin(async move {
        cancel.cancelled().await;
        ManagedProcessResult {
            process_id: String::new(),
            output: String::new(),
            exit_code: None,
            duration_ms: 0,
            timed_out: false,
            cancelled: true,
            blob_id: None,
            user_cancelled: false,
        }
    })
}

// ── Foreground spawning ──

#[tokio::test]
async fn spawn_foreground_blocks_until_complete() {
    let pm = ProcessManager::new();
    let start = Instant::now();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("test"),
            boxed_delayed(100, "ok"),
        )
        .await
        .unwrap();
    let elapsed = start.elapsed();
    assert!(
        elapsed >= Duration::from_millis(80),
        "should have blocked ~100ms"
    );
    assert!(handle.result.is_some());
}

#[tokio::test]
async fn spawn_foreground_returns_correct_result() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("echo"),
            boxed_immediate("hello", 0),
        )
        .await
        .unwrap();
    let result = handle.result.unwrap();
    assert_eq!(result.output, "hello");
    assert_eq!(result.exit_code, Some(0));
    assert!(!result.timed_out);
    assert!(!result.cancelled);
}

#[tokio::test]
async fn spawn_foreground_short_task() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("fast"),
            boxed_immediate("ok", 0),
        )
        .await
        .unwrap();
    assert!(handle.result.is_some());
    assert_eq!(handle.result.unwrap().output, "ok");
}

#[tokio::test]
async fn spawn_foreground_failed_exit_code() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("fail"),
            boxed_immediate("error", 1),
        )
        .await
        .unwrap();
    let result = handle.result.unwrap();
    assert_eq!(result.exit_code, Some(1));
    // State should be Failed.
    let info = pm.list_processes("s1");
    assert_eq!(info[0].state, "failed");
}

// ── Background spawning ──

#[tokio::test]
async fn spawn_background_returns_immediately() {
    let pm = ProcessManager::new();
    let start = Instant::now();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("slow"), boxed_delayed(500, "done"))
        .await
        .unwrap();
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_millis(50),
        "should not have blocked"
    );
    assert!(handle.result.is_none());
    assert!(!handle.process_id.is_empty());
}

#[tokio::test]
async fn spawn_background_handle_has_process_id() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(50, "ok"))
        .await
        .unwrap();
    assert!(handle.process_id.starts_with("proc-"));
}

#[tokio::test]
async fn spawn_background_result_available_after_completion() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(50, "done"))
        .await
        .unwrap();

    // Result not available immediately.
    assert!(pm.get_result(&handle.process_id).is_none());

    // Wait for completion.
    tokio::time::sleep(Duration::from_millis(150)).await;

    let result = pm.get_result(&handle.process_id);
    assert!(result.is_some());
    assert_eq!(result.unwrap().output, "done");
}

#[tokio::test]
async fn concurrent_background_processes() {
    let pm = ProcessManager::new();
    let mut handles = Vec::new();
    for i in 0..5 {
        let h = pm
            .spawn_managed(
                "s1",
                &format!("tc{i}"),
                make_config(&format!("cmd-{i}")),
                boxed_delayed(50, &format!("result-{i}")),
            )
            .await
            .unwrap();
        handles.push(h);
    }

    assert_eq!(pm.list_processes("s1").len(), 5);

    // Wait for all to complete.
    tokio::time::sleep(Duration::from_millis(200)).await;

    for (i, h) in handles.iter().enumerate() {
        let result = pm.get_result(&h.process_id).unwrap();
        assert_eq!(result.output, format!("result-{i}"));
    }
}

// ── Foreground-to-background promotion ──

#[tokio::test]
async fn promote_foreground_unblocks_caller() {
    let pm = Arc::new(ProcessManager::new());
    let pm2 = pm.clone();

    // Spawn foreground with a long-running task.
    let fg_handle = tokio::spawn(async move {
        pm2.spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("long"),
            boxed_delayed(5000, "done"),
        )
        .await
        .unwrap()
    });

    // Give it a moment to start.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Find the process and promote it.
    let processes = pm.list_processes("s1");
    assert_eq!(processes.len(), 1);
    let pid = &processes[0].process_id;
    assert_eq!(processes[0].state, "foreground");

    pm.promote_to_background(pid).unwrap();

    // The foreground call should return quickly now.
    let handle = tokio::time::timeout(Duration::from_millis(200), fg_handle)
        .await
        .expect("should have returned after promotion")
        .unwrap();

    assert!(
        handle.result.is_none(),
        "promoted handle should not have result"
    );
}

#[tokio::test]
async fn promote_then_process_completes_in_background() {
    let pm = Arc::new(ProcessManager::new());
    let pm2 = pm.clone();

    let fg_handle = tokio::spawn(async move {
        pm2.spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("cmd"),
            boxed_delayed(200, "bg-done"),
        )
        .await
        .unwrap()
    });

    tokio::time::sleep(Duration::from_millis(30)).await;

    let processes = pm.list_processes("s1");
    let pid = processes[0].process_id.clone();
    pm.promote_to_background(&pid).unwrap();

    let handle = fg_handle.await.unwrap();
    assert!(handle.result.is_none());

    // Process should still complete in background.
    tokio::time::sleep(Duration::from_millis(300)).await;

    let result = pm.get_result(&pid);
    assert!(result.is_some());
    assert_eq!(result.unwrap().output, "bg-done");
}

#[tokio::test]
async fn promote_nonexistent_returns_error() {
    let pm = ProcessManager::new();
    let err = pm.promote_to_background("proc-nonexistent").unwrap_err();
    assert!(matches!(err, ToolError::Validation { .. }));
}

#[tokio::test]
async fn promote_already_background_returns_error() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("bg"), boxed_delayed(500, "ok"))
        .await
        .unwrap();
    let err = pm.promote_to_background(&handle.process_id).unwrap_err();
    assert!(matches!(err, ToolError::Validation { .. }));
}

#[tokio::test]
async fn promote_already_completed_returns_error() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("fast"),
            boxed_immediate("ok", 0),
        )
        .await
        .unwrap();
    // Process is already completed.
    let err = pm.promote_to_background(&handle.process_id).unwrap_err();
    assert!(matches!(err, ToolError::Validation { .. }));
}

// ── Cancellation ──

#[tokio::test]
async fn cancel_running_process_fires_token() {
    let pm = ProcessManager::new();
    let inner_cancel = CancellationToken::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_config("cancellable"),
            boxed_cancellable(inner_cancel.clone()),
        )
        .await
        .unwrap();

    assert!(!inner_cancel.is_cancelled());
    pm.cancel_process(&handle.process_id, false).unwrap();

    // The PM cancellation should cause the task to complete.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = pm.get_result(&handle.process_id);
    assert!(result.is_some());
    assert!(result.unwrap().cancelled);
}

#[tokio::test]
async fn cancel_completed_process_is_noop() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("done"),
            boxed_immediate("ok", 0),
        )
        .await
        .unwrap();
    // Should not error.
    pm.cancel_process(&handle.process_id, false).unwrap();
}

#[tokio::test]
async fn cancel_nonexistent_returns_error() {
    let pm = ProcessManager::new();
    let err = pm.cancel_process("proc-nonexistent", false).unwrap_err();
    assert!(matches!(err, ToolError::Validation { .. }));
}

#[tokio::test]
async fn cancel_session_processes_cancels_all_for_session() {
    let pm = ProcessManager::new();
    pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(5000, "a"))
        .await
        .unwrap();
    pm.spawn_managed("s1", "tc2", make_config("b"), boxed_delayed(5000, "b"))
        .await
        .unwrap();
    pm.spawn_managed("s2", "tc3", make_config("c"), boxed_delayed(5000, "c"))
        .await
        .unwrap();

    pm.cancel_session_processes("s1");

    // s1 processes should be gone.
    assert!(pm.list_processes("s1").is_empty());
    // s2 should still be there.
    assert_eq!(pm.list_processes("s2").len(), 1);
}

#[tokio::test]
async fn cancel_all_cancels_everything() {
    let pm = ProcessManager::new();
    pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(5000, "a"))
        .await
        .unwrap();
    pm.spawn_managed("s2", "tc2", make_config("b"), boxed_delayed(5000, "b"))
        .await
        .unwrap();

    pm.cancel_all();

    assert!(pm.list_processes("s1").is_empty());
    assert!(pm.list_processes("s2").is_empty());
}

// ── Listing & querying ──

#[tokio::test]
async fn list_processes_filters_by_session() {
    let pm = ProcessManager::new();
    pm.spawn_managed("s1", "tc1", make_config("a"), boxed_delayed(500, "a"))
        .await
        .unwrap();
    pm.spawn_managed("s2", "tc2", make_config("b"), boxed_delayed(500, "b"))
        .await
        .unwrap();

    let s1_procs = pm.list_processes("s1");
    assert_eq!(s1_procs.len(), 1);
    assert_eq!(s1_procs[0].label, "a");

    let s2_procs = pm.list_processes("s2");
    assert_eq!(s2_procs.len(), 1);
    assert_eq!(s2_procs[0].label, "b");
}

#[tokio::test]
async fn list_processes_empty_session() {
    let pm = ProcessManager::new();
    assert!(pm.list_processes("nonexistent").is_empty());
}

#[tokio::test]
async fn list_processes_includes_recently_completed() {
    let pm = ProcessManager::new();
    pm.spawn_managed(
        "s1",
        "tc1",
        make_blocking_config("fast"),
        boxed_immediate("ok", 0),
    )
    .await
    .unwrap();

    // Just completed — should still be in list.
    let procs = pm.list_processes("s1");
    assert_eq!(procs.len(), 1);
    assert_eq!(procs[0].state, "completed");
}

#[tokio::test]
async fn get_result_returns_none_while_running() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("slow"), boxed_delayed(500, "ok"))
        .await
        .unwrap();
    assert!(pm.get_result(&handle.process_id).is_none());
}

#[tokio::test]
async fn get_result_returns_some_after_completion() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("fast"),
            boxed_immediate("done", 0),
        )
        .await
        .unwrap();
    let result = pm.get_result(&handle.process_id);
    assert!(result.is_some());
    assert_eq!(result.unwrap().output, "done");
}

#[tokio::test]
async fn get_result_nonexistent_returns_none() {
    let pm = ProcessManager::new();
    assert!(pm.get_result("proc-nonexistent").is_none());
}

// ── find_by_label ──

#[tokio::test]
async fn find_by_label_matches_prefix() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            ManagedProcessConfig {
                label: "display_stream:stream-123".into(),
                kind: ProcessKind::DisplayStream,
                timeout_ms: None,
                blocking_timeout_ms: None,
                sandbox: false,
            },
            boxed_delayed(500, "ok"),
        )
        .await
        .unwrap();

    let found = pm.find_by_label("s1", "display_stream:");
    assert_eq!(found, Some(handle.process_id));
}

#[tokio::test]
async fn find_by_label_wrong_session_returns_none() {
    let pm = ProcessManager::new();
    pm.spawn_managed(
        "s1",
        "tc1",
        ManagedProcessConfig {
            label: "display_stream:stream-1".into(),
            kind: ProcessKind::DisplayStream,
            timeout_ms: None,
            blocking_timeout_ms: None,
            sandbox: false,
        },
        boxed_delayed(500, "ok"),
    )
    .await
    .unwrap();

    assert!(pm.find_by_label("s2", "display_stream:").is_none());
}

#[tokio::test]
async fn find_by_label_completed_not_returned() {
    let pm = ProcessManager::new();
    pm.spawn_managed(
        "s1",
        "tc1",
        ManagedProcessConfig {
            label: "display_stream:stream-1".into(),
            kind: ProcessKind::DisplayStream,
            timeout_ms: None,
            blocking_timeout_ms: Some(60_000),
            sandbox: false,
        },
        boxed_immediate("ok", 0),
    )
    .await
    .unwrap();

    // Completed processes should not be found by label.
    assert!(pm.find_by_label("s1", "display_stream:").is_none());
}

// ── Timeout ──

#[tokio::test]
async fn blocking_timeout_auto_backgrounds() {
    let pm = ProcessManager::new();
    let config = ManagedProcessConfig {
        label: "timeout-test".into(),
        kind: ProcessKind::Shell,
        timeout_ms: Some(5000),
        blocking_timeout_ms: Some(100), // auto-background after 100ms
        sandbox: false,
    };
    let start = std::time::Instant::now();
    let handle = pm
        .spawn_managed("s1", "tc1", config, boxed_delayed(5000, "late"))
        .await
        .unwrap();

    // Should have returned due to blocking timeout (auto-backgrounded).
    let elapsed = start.elapsed();
    assert!(
        elapsed < std::time::Duration::from_millis(1000),
        "should return quickly after 100ms blocking timeout"
    );
    assert!(
        handle.result.is_none(),
        "auto-backgrounded: no inline result"
    );
}

#[tokio::test]
async fn foreground_no_timeout_completes_normally() {
    let pm = ProcessManager::new();
    let config = ManagedProcessConfig {
        label: "no-timeout".into(),
        kind: ProcessKind::Shell,
        timeout_ms: None,
        blocking_timeout_ms: Some(60_000),
        sandbox: false,
    };
    let handle = pm
        .spawn_managed("s1", "tc1", config, boxed_delayed(100, "done"))
        .await
        .unwrap();
    assert_eq!(handle.result.unwrap().output, "done");
}

// ── Process ID format ──

#[tokio::test]
async fn process_id_format_valid() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("test"),
            boxed_immediate("ok", 0),
        )
        .await
        .unwrap();
    assert!(handle.process_id.starts_with("proc-"));
    // After "proc-", the rest should be a valid UUID.
    let uuid_part = &handle.process_id[5..];
    assert!(Uuid::parse_str(uuid_part).is_ok());
}

// ── Promotion race with completion ──

#[tokio::test]
async fn promote_race_with_completion() {
    // If the process completes just before promotion, promotion should fail gracefully.
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_blocking_config("fast"),
            boxed_immediate("done", 0),
        )
        .await
        .unwrap();

    // Process is already completed.
    let result = pm.promote_to_background(&handle.process_id);
    assert!(result.is_err());
}

// ── wait_for_process ──

#[tokio::test]
async fn wait_already_completed() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed("s1", "tc1", make_config("fast"), boxed_immediate("done", 0))
        .await
        .unwrap();

    // Give the background task a moment to complete.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = pm.wait_for_process(&handle.process_id, 1000).await.unwrap();
    assert_eq!(result.output, "done");
    assert_eq!(result.exit_code, Some(0));
}

#[tokio::test]
async fn wait_completes_within_timeout() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_config("slow"),
            boxed_delayed(50, "finished"),
        )
        .await
        .unwrap();

    let result = pm.wait_for_process(&handle.process_id, 5000).await.unwrap();
    assert_eq!(result.output, "finished");
}

#[tokio::test]
async fn wait_timeout_returns_error() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_config("very-slow"),
            boxed_delayed(5000, "late"),
        )
        .await
        .unwrap();

    let err = pm.wait_for_process(&handle.process_id, 50).await;
    assert!(err.is_err());
    match err.unwrap_err() {
        ToolError::Timeout { timeout_ms } => assert_eq!(timeout_ms, 50),
        other => panic!("expected Timeout, got: {other:?}"),
    }
}

#[tokio::test]
async fn wait_for_cancelled_process() {
    let pm = ProcessManager::new();
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_config("cancel-me"),
            boxed_delayed(5000, "nope"),
        )
        .await
        .unwrap();

    pm.cancel_process(&handle.process_id, false).unwrap();
    // Give cancellation a moment to propagate.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let result = pm.wait_for_process(&handle.process_id, 1000).await.unwrap();
    assert!(result.cancelled);
}

#[tokio::test]
async fn wait_unknown_process_returns_error() {
    let pm = ProcessManager::new();
    let err = pm.wait_for_process("proc-nonexistent", 1000).await;
    assert!(err.is_err());
    match err.unwrap_err() {
        ToolError::Validation { message } => assert!(message.contains("not found")),
        other => panic!("expected Validation, got: {other:?}"),
    }
}

#[tokio::test]
async fn wait_concurrent_waiters_both_get_result() {
    let pm = Arc::new(ProcessManager::new());
    let handle = pm
        .spawn_managed(
            "s1",
            "tc1",
            make_config("shared"),
            boxed_delayed(50, "shared-result"),
        )
        .await
        .unwrap();
    let pid = handle.process_id.clone();

    let pm1 = pm.clone();
    let pid1 = pid.clone();
    let w1 = tokio::spawn(async move { pm1.wait_for_process(&pid1, 5000).await });

    let pm2 = pm.clone();
    let pid2 = pid;
    let w2 = tokio::spawn(async move { pm2.wait_for_process(&pid2, 5000).await });

    let r1 = w1.await.unwrap().unwrap();
    let r2 = w2.await.unwrap().unwrap();
    assert_eq!(r1.output, "shared-result");
    assert_eq!(r2.output, "shared-result");
}
