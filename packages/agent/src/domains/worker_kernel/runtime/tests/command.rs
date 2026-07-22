use super::*;

#[tokio::test]
async fn provider_api_keys_resolve_through_declared_runtime_bindings() {
    let (runtime, home) = test_runtime(None);
    let auth_path = crate::shared::foundation::paths::auth_path_for_home(home.path());
    let secret = "brave-provider-secret";
    crate::domains::auth::credentials::save_named_api_key(&auth_path, "brave", "Default", secret)
        .unwrap();

    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "printf '{\"value\":\"%s\"}' \"$TRON_SECRET_PROVIDER_BRAVE\"".to_owned(),
    ]);
    bundle.secret_bindings = vec![
        super::super::super::types::WorkerSecretBinding::Configured {
            name: "provider-brave".to_owned(),
            required: true,
        },
    ];

    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "provider-secret",
        ))
        .await
        .unwrap();
    assert_eq!(result.output, Some(json!({"value":"[REDACTED]"})));
    assert!(
        !serde_json::to_string(&runtime.store().runs_filtered(None, None, 10).unwrap())
            .unwrap()
            .contains(secret)
    );
}

#[tokio::test]
async fn secret_values_are_injected_then_redacted_from_durable_results() {
    let (captured_logs, _log_guard) = crate::shared::observability::capture_logs();
    let (runtime, home) = test_runtime(None);
    let vault = home.path().join("workspace/vault");
    std::fs::create_dir_all(&vault).unwrap();
    let secret = "top-secret-test-value";
    let undeclared_secret = "another-vault-only-secret";
    std::fs::write(vault.join("api-key"), secret).unwrap();
    std::fs::write(vault.join("other-key"), undeclared_secret).unwrap();
    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "printf '{\"value\":\"%s\"}' \"$TRON_SECRET_API_KEY\"".to_owned(),
    ]);
    bundle.secret_bindings = vec![super::super::super::types::WorkerSecretBinding::Optional(
        "api-key".to_owned(),
    )];
    let outcome = runtime.upsert(bundle.clone(), None).await.unwrap();
    let result = runtime
        .invoke(request(&outcome.worker.worker_id, json!({}), "secret"))
        .await
        .unwrap();
    assert_eq!(
        result.output,
        Some(json!({"value":"[REDACTED]"})),
        "secret worker result: {result:?}"
    );
    let diagnostics = format!(
        "{}{}",
        serde_json::to_string(&runtime.store().runs_filtered(None, None, 10).unwrap()).unwrap(),
        serde_json::to_string(
            &runtime
                .store()
                .inbox_filtered(None, None, None, 10)
                .unwrap(),
        )
        .unwrap()
    );
    assert!(!diagnostics.contains(secret));
    assert!(
        runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"copiedSecret":secret}),
                "secret-in-input",
            ))
            .await
            .unwrap_err()
            .contains("only through declared logical bindings")
    );
    assert_eq!(
        runtime.store().runs_filtered(None, None, 10).unwrap().len(),
        1
    );

    let mut failing = bundle.clone();
    failing
        .description
        .push_str(" with failure redaction evidence");
    failing.runner = WorkerRunner::Command {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "printf '%s' \"$TRON_SECRET_API_KEY\" >&2; exit 17".to_owned(),
        ],
    };
    let failed_version = runtime
        .upsert(failing, Some(&outcome.worker.worker_id))
        .await
        .unwrap();
    let failed = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "secret-error",
        ))
        .await
        .unwrap();
    assert_eq!(failed.status, "failed");
    assert!(
        failed
            .error
            .as_deref()
            .is_some_and(|error| error.contains("[REDACTED]") && !error.contains(secret))
    );
    let events = runtime
        .host
        .poll_stream_topic(
            "worker.invocations",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap();
    let operational_evidence = format!(
        "{}{}{}{}{:?}",
        serde_json::to_string(&runtime.store().inspect(&outcome.worker.worker_id).unwrap())
            .unwrap(),
        serde_json::to_string(&runtime.store().runs_filtered(None, None, 100).unwrap()).unwrap(),
        serde_json::to_string(
            &runtime
                .store()
                .inbox_filtered(None, None, None, 100)
                .unwrap(),
        )
        .unwrap(),
        serde_json::to_string(&events).unwrap(),
        captured_logs.events(),
    );
    assert!(!operational_evidence.contains(secret));
    for entry in walkdir::WalkDir::new(
        home.path()
            .join("workspace/workers")
            .join(&outcome.worker.worker_id),
    )
    .follow_links(false)
    {
        let entry = entry.unwrap();
        if entry.file_type().is_file() {
            let bytes = std::fs::read(entry.path()).unwrap();
            assert!(
                !bytes
                    .windows(secret.len())
                    .any(|window| window == secret.as_bytes()),
                "secret leaked into {}",
                entry.path().display()
            );
        }
    }
    assert_eq!(
        failed_version.worker.active_version, failed.worker_version,
        "redaction failure must still be pinned to the activated version"
    );

    bundle
        .files
        .insert("leak.txt".to_owned(), secret.to_owned());
    assert!(
        runtime
            .upsert(bundle, None)
            .await
            .unwrap_err()
            .contains("contains the value")
    );

    let mut undeclared_leak =
        command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    undeclared_leak
        .files
        .insert("undeclared.txt".to_owned(), undeclared_secret.to_owned());
    assert!(
        runtime
            .upsert(undeclared_leak, None)
            .await
            .unwrap_err()
            .contains("other-key")
    );
}

#[tokio::test]
async fn command_timeout_is_bounded_and_kills_the_child() {
    let temporary = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let error = run_worker_command(
        &WorkerCommand {
            command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 5".to_owned()],
            timeout_seconds: 1,
        },
        temporary.path(),
        None,
        &HashMap::new(),
        None,
    )
    .await
    .unwrap_err();
    assert!(error.contains("timed out"));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[tokio::test]
async fn successful_command_may_ignore_typed_input_without_a_broken_pipe_failure() {
    let temporary = tempfile::tempdir().unwrap();
    let output = run_worker_command(
        &WorkerCommand {
            command: vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "printf '{\"accepted\":true}'".to_owned(),
            ],
            timeout_seconds: 5,
        },
        temporary.path(),
        Some(&json!({"payload":"x".repeat(2_000_000)})),
        &HashMap::new(),
        None,
    )
    .await
    .unwrap();

    assert_eq!(output, json!({"accepted":true}));
}

#[tokio::test]
async fn worker_command_rejects_oversized_stdout_after_draining_the_child() {
    let temporary = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let error = run_worker_command(
        &WorkerCommand {
            command: vec![
                "python3".to_owned(),
                "-c".to_owned(),
                format!(
                    "import sys; sys.stdout.write('x'*{})",
                    MAX_PROCESS_CAPTURE_BYTES + 1
                ),
            ],
            timeout_seconds: 5,
        },
        temporary.path(),
        None,
        &HashMap::new(),
        None,
    )
    .await
    .unwrap_err();

    assert!(error.contains("capture ceiling"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(3));
}
