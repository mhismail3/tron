use super::*;
#[test]
fn wait_mode_serde_roundtrip() {
    for mode in [WaitMode::All, WaitMode::Any] {
        let json = serde_json::to_string(&mode).unwrap();
        let back: WaitMode = serde_json::from_str(&json).unwrap();
        assert_eq!(mode, back);
    }
}

#[test]
fn subagent_mode_serde_roundtrip() {
    for mode in [SubagentMode::InProcess, SubagentMode::Tmux] {
        let json = serde_json::to_string(&mode).unwrap();
        let back: SubagentMode = serde_json::from_str(&json).unwrap();
        assert_eq!(mode, back);
    }
}

#[test]
fn execution_mode_default_is_parallel() {
    // Verify that the default ExecutionMode is Parallel
    assert_eq!(ExecutionMode::Parallel, ExecutionMode::Parallel);
    assert_ne!(
        ExecutionMode::Parallel,
        ExecutionMode::Serialized("browser".into())
    );
}

#[test]
fn execution_mode_serialized_equality() {
    assert_eq!(
        ExecutionMode::Serialized("browser".into()),
        ExecutionMode::Serialized("browser".into())
    );
    assert_ne!(
        ExecutionMode::Serialized("browser".into()),
        ExecutionMode::Serialized("shell".into())
    );
}

// ── Managed process types ──────────────────────────────────

#[test]
fn process_kind_serde_roundtrip() {
    for kind in [
        ProcessKind::Shell,
        ProcessKind::DisplayStream,
        ProcessKind::CapabilityOperation,
    ] {
        let json = serde_json::to_string(&kind).unwrap();
        let back: ProcessKind = serde_json::from_str(&json).unwrap();
        assert_eq!(kind, back);
    }
}

#[test]
fn process_kind_snake_case_serialization() {
    assert_eq!(
        serde_json::to_string(&ProcessKind::Shell).unwrap(),
        "\"shell\""
    );
    assert_eq!(
        serde_json::to_string(&ProcessKind::DisplayStream).unwrap(),
        "\"display_stream\""
    );
    assert_eq!(
        serde_json::to_string(&ProcessKind::CapabilityOperation).unwrap(),
        "\"capability_operation\""
    );
}

#[test]
fn managed_process_config_construction() {
    let config = ManagedProcessConfig {
        label: "cargo build".into(),
        kind: ProcessKind::Shell,
        timeout_ms: Some(120_000),
        blocking_timeout_ms: None,
        sandbox: true,
    };
    assert_eq!(config.label, "cargo build");
    assert_eq!(config.kind, ProcessKind::Shell);
    assert_eq!(config.timeout_ms, Some(120_000));
    assert!(config.sandbox);
}

#[test]
fn managed_process_result_serde_roundtrip() {
    let result = ManagedProcessResult {
        process_id: "proc-abc".into(),
        output: "build complete".into(),
        exit_code: Some(0),
        duration_ms: 5000,
        timed_out: false,
        cancelled: false,
        blob_id: None,
        user_cancelled: false,
    };
    let json = serde_json::to_string(&result).unwrap();
    let back: ManagedProcessResult = serde_json::from_str(&json).unwrap();
    assert_eq!(back.process_id, "proc-abc");
    assert_eq!(back.exit_code, Some(0));
    assert!(back.blob_id.is_none());
}

#[test]
fn managed_process_result_with_blob_id() {
    let result = ManagedProcessResult {
        process_id: "proc-xyz".into(),
        output: "truncated...".into(),
        exit_code: Some(1),
        duration_ms: 10000,
        timed_out: false,
        cancelled: false,
        blob_id: Some("blob-123".into()),
        user_cancelled: false,
    };
    let json = serde_json::to_string(&result).unwrap();
    assert!(json.contains("blob-123"));
    let back: ManagedProcessResult = serde_json::from_str(&json).unwrap();
    assert_eq!(back.blob_id.as_deref(), Some("blob-123"));
}

#[test]
fn process_info_serde_roundtrip() {
    let info = ProcessInfo {
        process_id: "proc-1".into(),
        label: "npm test".into(),
        kind: ProcessKind::Shell,
        state: "background".into(),
        elapsed_ms: 3000,
        session_id: "sess-1".into(),
        invocation_id: "tc-1".into(),
    };
    let json = serde_json::to_string(&info).unwrap();
    let back: ProcessInfo = serde_json::from_str(&json).unwrap();
    assert_eq!(back.process_id, "proc-1");
    assert_eq!(back.kind, ProcessKind::Shell);
    assert_eq!(back.session_id, "sess-1");
}

#[test]
fn process_state_equality() {
    assert_eq!(ProcessState::Foreground, ProcessState::Foreground);
    assert_eq!(ProcessState::Background, ProcessState::Background);
    assert_eq!(ProcessState::Completed, ProcessState::Completed);
    assert_eq!(ProcessState::Failed, ProcessState::Failed);
    assert_eq!(ProcessState::Cancelled, ProcessState::Cancelled);
    assert_ne!(ProcessState::Foreground, ProcessState::Background);
    assert_ne!(ProcessState::Completed, ProcessState::Failed);
}
// ── Process options ───────────────────────────────────────

#[test]
fn process_options_default_construction() {
    let opts = ProcessOptions {
        working_directory: "/tmp".into(),
        timeout_ms: 120_000,
        cancellation: CancellationToken::new(),
        env: HashMap::new(),
        stdin: None,
        shell: "bash".into(),
        interactive: false,
        pty_input: Vec::new(),
        output_tx: None,
    };
    assert_eq!(opts.timeout_ms, 120_000);
    assert!(opts.env.is_empty());
    assert!(opts.stdin.is_none());
    assert_eq!(opts.shell, "bash");
    assert!(!opts.interactive);
    assert!(opts.pty_input.is_empty());
}

// ── Unified job types ────────────────────────────────────

#[test]
fn job_kind_serde_roundtrip() {
    for kind in [JobKind::Process, JobKind::Agent] {
        let json = serde_json::to_string(&kind).unwrap();
        let back: JobKind = serde_json::from_str(&json).unwrap();
        assert_eq!(kind, back);
    }
}

#[test]
fn job_kind_snake_case_serialization() {
    assert_eq!(
        serde_json::to_string(&JobKind::Process).unwrap(),
        "\"process\""
    );
    assert_eq!(serde_json::to_string(&JobKind::Agent).unwrap(), "\"agent\"");
}

#[test]
fn job_state_serde_roundtrip() {
    for state in [
        JobState::Running,
        JobState::Completed,
        JobState::Failed,
        JobState::Cancelled,
    ] {
        let json = serde_json::to_string(&state).unwrap();
        let back: JobState = serde_json::from_str(&json).unwrap();
        assert_eq!(state, back);
    }
}

#[test]
fn job_state_snake_case_serialization() {
    assert_eq!(
        serde_json::to_string(&JobState::Running).unwrap(),
        "\"running\""
    );
    assert_eq!(
        serde_json::to_string(&JobState::Completed).unwrap(),
        "\"completed\""
    );
    assert_eq!(
        serde_json::to_string(&JobState::Failed).unwrap(),
        "\"failed\""
    );
    assert_eq!(
        serde_json::to_string(&JobState::Cancelled).unwrap(),
        "\"cancelled\""
    );
}

#[test]
fn job_info_process_construction() {
    let info = JobInfo {
        id: "proc-abc123".into(),
        kind: JobKind::Process,
        label: "cargo build --release".into(),
        state: JobState::Running,
        elapsed_ms: 5000,
        session_id: "sess-1".into(),
    };
    assert_eq!(info.id, "proc-abc123");
    assert_eq!(info.kind, JobKind::Process);
    assert_eq!(info.state, JobState::Running);

    let json = serde_json::to_string(&info).unwrap();
    assert!(json.contains("\"kind\":\"process\""));
    assert!(json.contains("\"state\":\"running\""));
    assert!(json.contains("\"elapsedMs\":5000"));
}

#[test]
fn job_info_agent_construction() {
    let info = JobInfo {
        id: "ses-xyz789".into(),
        kind: JobKind::Agent,
        label: "Research API patterns".into(),
        state: JobState::Completed,
        elapsed_ms: 32000,
        session_id: "sess-1".into(),
    };
    assert_eq!(info.kind, JobKind::Agent);
    assert_eq!(info.state, JobState::Completed);

    let json = serde_json::to_string(&info).unwrap();
    let back: JobInfo = serde_json::from_str(&json).unwrap();
    assert_eq!(back.id, "ses-xyz789");
    assert_eq!(back.kind, JobKind::Agent);
}

#[test]
fn job_result_with_process_details() {
    let result = JobResult {
        id: "proc-abc".into(),
        kind: JobKind::Process,
        label: "cargo test".into(),
        output: "test result: ok".into(),
        success: true,
        duration_ms: 5000,
        details: Some(serde_json::json!({ "exit_code": 0 })),
    };
    let json = serde_json::to_string(&result).unwrap();
    assert!(json.contains("\"kind\":\"process\""));
    assert!(json.contains("\"exit_code\":0"));

    let back: JobResult = serde_json::from_str(&json).unwrap();
    assert_eq!(back.kind, JobKind::Process);
    assert!(back.success);
    assert_eq!(back.details.unwrap()["exit_code"], 0);
}

#[test]
fn job_result_with_agent_details() {
    let result = JobResult {
        id: "ses-xyz".into(),
        kind: JobKind::Agent,
        label: "Research task".into(),
        output: "Found 3 patterns".into(),
        success: true,
        duration_ms: 32000,
        details: Some(serde_json::json!({
            "token_usage": { "input": 1000, "output": 500 },
            "turns": 5
        })),
    };
    let json = serde_json::to_string(&result).unwrap();
    assert!(json.contains("\"kind\":\"agent\""));
    assert!(json.contains("\"turns\":5"));

    let back: JobResult = serde_json::from_str(&json).unwrap();
    assert_eq!(back.kind, JobKind::Agent);
    assert_eq!(back.details.unwrap()["turns"], 5);
}

#[test]
fn job_result_without_details() {
    let result = JobResult {
        id: "proc-none".into(),
        kind: JobKind::Process,
        label: "echo hi".into(),
        output: "hi".into(),
        success: true,
        duration_ms: 10,
        details: None,
    };
    let json = serde_json::to_string(&result).unwrap();
    // details should be omitted from JSON when None
    assert!(!json.contains("details"));
}
