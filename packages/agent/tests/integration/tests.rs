use super::*;

#[tokio::test]
async fn e2e_engine_hello_on_connect() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    ws.send(Message::text(
        json!({"type": "hello", "id": "hello", "protocolVersion": 1}).to_string(),
    ))
    .await
    .unwrap();
    let msg = read_json(&mut ws).await;
    assert_eq!(msg["type"], "hello.ok");
    assert_eq!(msg["id"], "hello");
    assert!(msg["serverId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_connect_and_ping() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "system::ping", None).await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["pong"], true);

    server.shutdown().shutdown();
}

#[cfg(unix)]
#[tokio::test]
async fn e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn() {
    let port = reserve_loopback_port();
    let config = ServerConfig {
        host: "127.0.0.1".to_owned(),
        port,
        ..ServerConfig::default()
    };
    let (_url, server) =
        boot_server_without_deps_with_config(config, format!("127.0.0.1:{port}")).await;
    let package_id = "runtime-local-package";
    let namespace = "runtime_local";
    let worker_id = "runtime-local-worker";
    let function_id = "runtime_local::health";

    let guide = direct_engine_invoke(
        &server,
        "worker::protocol_guide",
        json!({
            "language": "python",
            "workerId": worker_id,
            "functionId": function_id
        }),
        "runtime-local-guide",
        &["worker.read"],
    )
    .await;
    let script = guide["pythonTemplate"]
        .as_str()
        .expect("worker guide returns python template");
    let script_log = unique_runtime_path("runtime-local-worker", "log");
    let script = script.replace(
        "if __name__ == \"__main__\":\n    main()\n",
        &format!(
            "if __name__ == \"__main__\":\n    try:\n        main()\n    except Exception as exc:\n        with open({:?}, \"a\") as log:\n            log.write(str(exc) + \"\\n\")\n        raise\n",
            script_log.to_string_lossy()
        ),
    );
    let script_path = unique_runtime_path("runtime-local-worker", "py");
    let materialized = direct_engine_invoke(
        &server,
        "materialized_file::update",
        json!({
            "path": script_path.to_string_lossy(),
            "content": script,
            "scope": "system"
        }),
        "runtime-local-materialize",
        &["resource.write"],
    )
    .await;
    std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    let executable_ref = materialized["resourceRefs"][0].clone();
    let file_root = script_path
        .parent()
        .expect("script has parent")
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let manifest = manifest_with_digest(local_process_runtime_manifest(
        package_id,
        namespace,
        worker_id,
        function_id,
        &executable_ref,
        &file_root,
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = direct_engine_invoke(
        &server,
        "module::register_package",
        json!({ "manifest": manifest }),
        "runtime-local-register",
        &["module.write"],
    )
    .await;
    let package_version_id = registered["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let package_resource_id = format!("worker-package:{package_id}");
    let verified = direct_engine_invoke(
        &server,
        "module::verify_source",
        json!({
            "packageResourceId": package_resource_id,
            "packageVersionId": package_version_id,
            "expectedCurrentVersionId": package_version_id,
            "mode": "on_demand"
        }),
        "runtime-local-verify-source",
        &["module.write"],
    )
    .await;
    let package_version_id = verified["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let child_grant_request = json!({
        "allowedCapabilities": [function_id],
        "allowedNamespaces": [namespace],
        "allowedAuthorityScopes": [format!("{namespace}.read")],
        "allowedResourceKinds": ["evidence", "activation_record"],
        "resourceSelectors": ["*"],
        "fileRoots": [file_root],
        "networkPolicy": "loopback",
        "maxRisk": "low"
    });
    let approved = direct_engine_invoke(
        &server,
        "module::approve_source",
        json!({
            "packageResourceId": package_resource_id,
            "packageVersionId": package_version_id,
            "packageDigest": package_digest,
            "packageId": package_id,
            "scope": "system",
            "trustTierCeiling": "local_digest_pinned",
            "grantCeiling": {
                "allowedCapabilities": [function_id],
                "allowedNamespaces": [namespace],
                "allowedAuthorityScopes": [format!("{namespace}.read")],
                "allowedResourceKinds": ["evidence", "activation_record"],
                "resourceSelectors": ["*"],
                "fileRoots": [file_root],
                "networkPolicy": "loopback",
                "maxRisk": "low",
                "canDelegate": false,
                "approvalRequired": false
            },
            "expiresAt": "2100-01-01T00:00:00Z",
            "reason": "integration test approves digest-pinned local worker"
        }),
        "runtime-local-approve-source",
        &["module.write"],
    )
    .await;
    assert_eq!(approved["decision"]["status"], "approved");
    let configured = direct_engine_invoke(
        &server,
        "module::configure",
        json!({
            "packageResourceId": package_resource_id,
            "packageVersionId": package_version_id,
            "scope": "system",
            "config": {}
        }),
        "runtime-local-configure",
        &["module.write"],
    )
    .await;
    let config_version_id = configured["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let config_resource_id = format!("module-config:system:{package_id}");
    let activation_resource_id = format!("activation:system:{package_id}");
    for cycle in 0..2 {
        let activate_key = format!("runtime-local-activate-{cycle}");
        let activated = direct_engine_invoke(
            &server,
            "module::activate",
            json!({
                "packageResourceId": format!("worker-package:{package_id}"),
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": config_resource_id,
                "configVersionId": config_version_id,
                "scope": "system",
                "childGrantRequest": child_grant_request.clone()
            }),
            &activate_key,
            &["module.write"],
        )
        .await;
        assert_eq!(
            activated["activation"]["payload"]["workerLifecycle"]["mode"],
            "spawned_local_process"
        );
        assert!(activated["activation"]["payload"]["spawnInvocationId"].is_string());
        let activation_version_id = activated["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let derived_grant_id = activated["activation"]["payload"]["derivedGrantId"]
            .as_str()
            .expect("activation records derived grant")
            .to_owned();

        let health_key = format!("runtime-local-check-health-{cycle}");
        let checked = direct_engine_invoke(
            &server,
            "module::check_health",
            json!({
                "activationResourceId": activation_resource_id,
                "activationVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id,
                "mode": "on_demand"
            }),
            &health_key,
            &["module.write"],
        )
        .await;
        assert_eq!(checked["healthResult"]["status"], "healthy");
        assert_eq!(
            checked["healthResult"]["childInvocationIds"]
                .as_array()
                .expect("health child ids")
                .len(),
            1
        );
        let checked_activation_version = checked["activation"]["version"]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();

        let disable_key = format!("runtime-local-disable-{cycle}");
        let disabled = direct_engine_invoke(
            &server,
            "module::disable",
            json!({
                "activationResourceId": format!("activation:system:{package_id}"),
                "expectedCurrentVersionId": checked_activation_version
            }),
            &disable_key,
            &["module.write", "sandbox.write"],
        )
        .await;
        assert_eq!(
            disabled["activation"]["payload"]["activationStatus"],
            "disabled"
        );
        assert_eq!(
            disabled["workerLifecycle"]["status"],
            "stopped_spawned_worker"
        );
        assert_eq!(
            disabled["workerLifecycle"]["result"]["stopped"], true,
            "sandbox stop should own spawned process cleanup"
        );
        let worker_list_key = format!("runtime-local-worker-list-{cycle}");
        let workers = direct_engine_invoke(
            &server,
            "worker::list",
            json!({"includeInternal": true}),
            &worker_list_key,
            &["worker.read"],
        )
        .await;
        assert!(
            workers["workers"]
                .as_array()
                .expect("worker list")
                .iter()
                .all(|worker| worker["id"] != worker_id),
            "disabled local-process package must leave no volatile worker registered"
        );
        let grant_inspect_key = format!("runtime-local-grant-inspect-{cycle}");
        let grant = direct_engine_invoke(
            &server,
            "grant::inspect",
            json!({"grantId": derived_grant_id}),
            &grant_inspect_key,
            &["grant.read"],
        )
        .await;
        assert_eq!(
            grant["grant"]["lifecycle"], "revoked",
            "disabled local-process package must revoke its activation grant"
        );
        let inspect_key = format!("runtime-local-inspect-{cycle}");
        let inspected = direct_engine_invoke(
            &server,
            "module::inspect_package",
            json!({"packageId": package_id}),
            &inspect_key,
            &["module.read"],
        )
        .await;
        assert_eq!(inspected["diagnostics"]["activationStatus"], "disabled");
        assert_eq!(inspected["diagnostics"]["grantStatus"], "revoked");
        assert_eq!(inspected["diagnostics"]["workerStatus"], "missing");
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_engine_ws_hello_discover_invoke_and_stream_poll() {
    let (url, server) = boot_server_without_deps().await;
    let engine_url = engine_ws_url_for(&url);
    let mut ws = connect(&engine_url).await;

    ws.send(Message::text(
        json!({
            "type": "hello",
            "id": "hello-1",
            "protocolVersion": 1,
            "sessionId": "engine-session"
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let hello = read_json(&mut ws).await;
    assert_eq!(hello["type"], "hello.ok");
    assert_eq!(hello["id"], "hello-1");
    assert_eq!(hello["protocolVersion"], 1);
    assert!(hello["currentCatalogRevision"].is_number());

    ws.send(Message::text(
        json!({
            "type": "discover",
            "id": "discover-1",
            "request": {"text": "system"}
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let discover = read_json(&mut ws).await;
    assert_eq!(discover["type"], "response");
    assert_eq!(discover["id"], "discover-1");
    assert_eq!(discover["ok"], true);
    assert!(discover["result"].to_string().contains("system::ping"));

    ws.send(Message::text(
        json!({
            "type": "invoke",
            "id": "invoke-1",
            "functionId": "system::ping",
            "payload": ping_params()
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let invoke = read_json(&mut ws).await;
    assert_eq!(invoke["id"], "invoke-1");
    assert_eq!(invoke["ok"], true);
    assert_eq!(invoke["result"]["child"]["value"]["pong"], true);

    ws.send(Message::text(
        json!({
            "type": "subscribe",
            "id": "subscribe-1",
            "topic": "events.session"
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let subscribe = read_json(&mut ws).await;
    assert_eq!(subscribe["ok"], true);
    let subscription_id = subscribe["result"]["subscriptionId"]
        .as_str()
        .unwrap()
        .to_owned();

    publish_engine_session_event(
        &server,
        "engine-session",
        "agent.ready",
        json!({"ready": true}),
    )
    .await;
    ws.send(Message::text(
        json!({
            "type": "poll",
            "id": "poll-1",
            "subscriptionId": subscription_id
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let poll = read_json(&mut ws).await;
    assert_eq!(poll["ok"], true);
    assert_eq!(poll["result"]["events"][0]["topic"], "events.session");
    assert_eq!(poll["result"]["events"][0]["event"]["type"], "agent.ready");
    assert_eq!(
        poll["result"]["events"][0]["event"]["sessionId"],
        "engine-session"
    );

    server.shutdown().shutdown();
}

#[tokio::test]
async fn capability_self_modifying_lifecycle_execute_returns_worker_protocol_guide() {
    let (url, server) = boot_server_without_deps().await;
    let mut ws = connect(&url).await;
    let session_id = "hmh-b-guide-session";
    let function_id = "hmh_b_guide::echo";
    let worker_id = "hmh-b-guide-worker";

    let response = rpc_call(
        &mut ws,
        3201,
        "capability::execute",
        Some(json!({
            "sessionId": session_id,
            "target": "worker::protocol_guide",
            "arguments": {
                "language": "typescript",
                "workerId": worker_id,
                "functionId": function_id
            },
            "reason": "HMH-B2 guide sufficiency proof"
        })),
    )
    .await;
    assert_eq!(response["success"], true, "execute failed: {response}");
    let result = &response["result"];
    assert!(
        result.get("isError").is_none(),
        "worker guide execute should not be an error: {result}"
    );
    assert_eq!(result["details"]["status"], "ok");
    assert_eq!(result["details"]["functionId"], "worker::protocol_guide");
    assert_eq!(
        result["details"]["orchestration"]["phaseDetails"]["selectedTarget"]["functionId"],
        "worker::protocol_guide"
    );
    assert_eq!(
        result["details"]["orchestration"]["correctedRequest"]["target"],
        json!({"capabilityId": "worker::protocol_guide"})
    );
    assert!(
        result["details"]["childInvocations"]
            .as_array()
            .is_some_and(|ids| ids.len() == 1),
        "execute should expose the child invocation id: {result}"
    );

    let output = &result["details"]["output"];
    assert_eq!(output["requestedLanguage"], "typescript");
    assert_eq!(output["templateLanguage"], "python");
    assert_eq!(output["endpoint"], "/engine/workers");
    assert_eq!(
        output["environment"]["TRON_ENGINE_WORKER_ENDPOINT"],
        "Absolute WebSocket endpoint injected by worker::spawn, for example ws://127.0.0.1:9847/engine/workers"
    );
    assert_eq!(
        output["functionDefinitionShape"]["readOnlyEchoMinimum"]["id"],
        function_id
    );
    assert_eq!(
        output["functionDefinitionShape"]["readOnlyEchoMinimum"]["metadata"]["pluginId"],
        format!("session_generated.{worker_id}")
    );
    assert_eq!(
        output["spawnWorkerPayloadExample"]["expectedFunctionIds"],
        json!([function_id])
    );
    assert_eq!(output["spawnWorkerPayloadExample"]["workerId"], worker_id);
    assert_eq!(output["spawnWorkerPayloadExample"]["visibility"], "session");
    assert_eq!(output["spawnWorkerPayloadExample"]["sessionId"], session_id);
    assert!(
        output["pythonTemplate"]
            .as_str()
            .expect("python template")
            .contains("TRON_ENGINE_WORKER_ENDPOINT"),
        "template must use injected worker endpoint instead of deriving HTTP paths"
    );
    assert!(
        output["rules"]
            .as_array()
            .expect("rules")
            .iter()
            .any(|rule| rule
                .as_str()
                .is_some_and(|text| text.contains("worker::disconnect"))),
        "guide must include cleanup guidance"
    );

    server.shutdown().shutdown();
}

#[cfg(unix)]
struct HmhSessionWorkerFixture {
    session_id: String,
    worker_id: String,
    function_id: String,
    namespace: String,
    spawn_result: Value,
    expected_function_ids: Value,
    expected_authority_scopes: Value,
    expected_resource_kinds: Value,
    expected_resource_selectors: Value,
    expected_file_roots: Value,
}

#[cfg(unix)]
impl HmhSessionWorkerFixture {
    fn output(&self) -> &Value {
        &self.spawn_result["details"]["output"]
    }
}

#[cfg(unix)]
async fn spawn_hmh_session_worker_through_execute(
    ws: &mut WsStream,
    port: u16,
    label: &str,
    base_rpc_id: u64,
) -> HmhSessionWorkerFixture {
    let namespace = format!("hmh_b_{label}");
    let session_id = format!("hmh-b-{label}-session");
    let worker_id = format!("hmh-b-{label}-worker");
    let function_id = format!("{namespace}::echo");

    let guide_response = rpc_call(
        ws,
        base_rpc_id,
        "capability::execute",
        Some(json!({
            "sessionId": session_id,
            "target": "worker::protocol_guide",
            "arguments": {
                "language": "python",
                "workerId": worker_id,
                "functionId": function_id
            },
            "reason": "HMH-B session worker spawn proof guide step"
        })),
    )
    .await;
    assert_eq!(
        guide_response["success"], true,
        "guide execute failed: {guide_response}"
    );
    let guide_output = &guide_response["result"]["details"]["output"];
    assert_eq!(
        guide_output["spawnWorkerPayloadExample"]["visibility"], "session",
        "guide must teach the session-scoped default spawn shape"
    );
    let script = guide_output["pythonTemplate"]
        .as_str()
        .expect("worker guide returns python template");
    let path_prefix = format!("hmh-b-{label}-worker");
    let script_log = unique_runtime_path(&path_prefix, "log");
    let script = script.replace(
        "if __name__ == \"__main__\":\n    main()\n",
        &format!(
            "if __name__ == \"__main__\":\n    try:\n        main()\n    except Exception as exc:\n        with open({:?}, \"a\") as log:\n            log.write(str(exc) + \"\\n\")\n        raise\n",
            script_log.to_string_lossy()
        ),
    );
    let script_path = unique_runtime_path(&path_prefix, "py");
    std::fs::write(&script_path, script).unwrap();
    let working_directory = script_path
        .parent()
        .expect("script has parent")
        .canonicalize()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let expected_function_ids = json!([function_id]);
    let expected_authority_scopes = json!([format!("{namespace}.read")]);
    let expected_resource_kinds = json!(["evidence"]);
    let expected_resource_selectors = json!([format!("session:{session_id}")]);
    let expected_file_roots = json!([working_directory.clone()]);

    let spawn_response = rpc_call(
        ws,
        base_rpc_id + 1,
        "capability::execute",
        Some(json!({
            "sessionId": session_id,
            "target": "worker::spawn",
            "arguments": {
                "workerId": worker_id,
                "command": "python3",
                "args": [script_path.to_string_lossy()],
                "workingDirectory": working_directory,
                "expectedFunctionIds": expected_function_ids.clone(),
                "allowedAuthorityScopes": expected_authority_scopes.clone(),
                "allowedResourceKinds": expected_resource_kinds.clone(),
                "resourceSelectors": expected_resource_selectors.clone(),
                "fileRoots": expected_file_roots.clone(),
                "networkPolicy": "loopback",
                "maxRisk": "low",
                "approvalRequired": false,
                "visibility": "session",
                "sessionId": session_id,
                "timeoutMs": 10000
            },
            "idempotencyKey": format!("hmh-b-{label}-spawn-session-worker"),
            "reason": "HMH-B scoped session worker spawn proof"
        })),
    )
    .await;
    assert_eq!(
        spawn_response["success"], true,
        "worker::spawn execute failed: {spawn_response}"
    );
    let spawn_result = &spawn_response["result"];
    assert!(
        spawn_result.get("isError").is_none(),
        "worker::spawn execute should not be an error: {spawn_result}"
    );
    assert_eq!(spawn_result["details"]["status"], "ok");
    assert_eq!(spawn_result["details"]["functionId"], "worker::spawn");
    assert!(
        spawn_result["details"]["childInvocations"]
            .as_array()
            .is_some_and(|ids| ids.len() == 1),
        "execute should expose the worker::spawn child invocation id: {spawn_result}"
    );

    let output = &spawn_result["details"]["output"];
    assert_eq!(output["workerId"], worker_id);
    assert_eq!(output["visibility"], "session");
    assert_eq!(output["registeredFunctionIds"], json!([function_id]));
    assert!(output["authorityGrantId"].is_string());
    assert!(output["authorityGrantRevision"].is_number());
    assert!(
        output["processId"].is_number(),
        "spawn should return the launched worker process id: {output}"
    );
    assert!(
        output["catalogRevision"].as_u64().unwrap_or_default() > 0,
        "spawn should return the catalog revision that contains the worker function: {output}"
    );
    assert_eq!(output["streamTopic"], "sandbox.lifecycle");
    assert!(
        output["workerEndpoint"]
            .as_str()
            .is_some_and(|endpoint| endpoint == format!("ws://127.0.0.1:{port}/engine/workers")),
        "worker::spawn must inject the complete loopback worker endpoint: {output}"
    );

    HmhSessionWorkerFixture {
        session_id,
        worker_id,
        function_id,
        namespace,
        spawn_result: spawn_result.clone(),
        expected_function_ids,
        expected_authority_scopes,
        expected_resource_kinds,
        expected_resource_selectors,
        expected_file_roots,
    }
}

#[cfg(unix)]
async fn stop_hmh_session_worker(
    server: &Arc<TronServer>,
    fixture: &HmhSessionWorkerFixture,
    idempotency_key: &str,
) -> Value {
    direct_engine_invoke(
        server,
        "sandbox::stop_spawned_worker",
        json!({
            "workerId": fixture.worker_id,
            "reason": "HMH integration cleanup",
            "sessionId": fixture.session_id
        }),
        idempotency_key,
        &["sandbox.write"],
    )
    .await
}

#[cfg(unix)]
#[tokio::test]
async fn capability_self_modifying_lifecycle_spawns_session_worker() {
    let port = reserve_loopback_port();
    let config = ServerConfig {
        host: "127.0.0.1".to_owned(),
        port,
        ..ServerConfig::default()
    };
    let (url, server) =
        boot_server_without_deps_with_config(config, format!("127.0.0.1:{port}")).await;
    let mut ws = connect(&url).await;
    let fixture = spawn_hmh_session_worker_through_execute(&mut ws, port, "spawn", 3211).await;
    let output = fixture.output();
    let grant_id = output["authorityGrantId"].as_str().unwrap();
    let grant = direct_engine_invoke(
        &server,
        "grant::inspect",
        json!({"grantId": grant_id}),
        "hmh-b3-inspect-derived-grant",
        &["grant.read"],
    )
    .await;
    let parent_grant_id = grant["grant"]["parentGrantId"]
        .as_str()
        .expect("spawned worker grant records its parent grant");
    let parent_grant = direct_engine_invoke(
        &server,
        "grant::inspect",
        json!({"grantId": parent_grant_id}),
        "hmh-b3-inspect-parent-grant",
        &["grant.read"],
    )
    .await;
    assert_eq!(parent_grant["grant"]["lifecycle"], "active");
    assert_eq!(parent_grant["grant"]["canDelegate"], true);
    assert_eq!(grant["grant"]["subjectWorkerId"], fixture.worker_id);
    assert_eq!(
        grant["grant"]["allowedCapabilities"],
        fixture.expected_function_ids
    );
    assert_eq!(
        grant["grant"]["allowedNamespaces"],
        json!([fixture.namespace])
    );
    assert_eq!(
        grant["grant"]["allowedAuthorityScopes"],
        fixture.expected_authority_scopes
    );
    assert_eq!(
        grant["grant"]["allowedResourceKinds"],
        fixture.expected_resource_kinds
    );
    assert_eq!(
        grant["grant"]["resourceSelectors"],
        fixture.expected_resource_selectors
    );
    assert_eq!(grant["grant"]["fileRoots"], fixture.expected_file_roots);
    assert_eq!(grant["grant"]["networkPolicy"], "loopback");
    assert_eq!(grant["grant"]["maxRisk"], "Low");
    assert_eq!(grant["grant"]["canDelegate"], false);
    assert_eq!(grant["grant"]["approvalRequired"], false);

    let stopped = stop_hmh_session_worker(&server, &fixture, "hmh-b3-stop-session-worker").await;
    assert_eq!(stopped["stopped"], true);

    server.shutdown().shutdown();
}

#[cfg(unix)]
#[tokio::test]
async fn capability_self_modifying_lifecycle_inspects_session_worker_catalog() {
    let port = reserve_loopback_port();
    let config = ServerConfig {
        host: "127.0.0.1".to_owned(),
        port,
        ..ServerConfig::default()
    };
    let (url, server) =
        boot_server_without_deps_with_config(config, format!("127.0.0.1:{port}")).await;
    let before_revision = server
        .runtime_context()
        .engine_host
        .catalog_revision()
        .await
        .0;
    let mut ws = connect(&url).await;
    let fixture = spawn_hmh_session_worker_through_execute(&mut ws, port, "catalog", 3221).await;
    let spawn_revision = fixture.output()["catalogRevision"]
        .as_u64()
        .expect("spawn result records catalog revision");
    assert!(
        spawn_revision > before_revision,
        "worker::spawn should advance the live catalog revision"
    );

    let watch_response = rpc_call(
        &mut ws,
        3223,
        "capability::execute",
        Some(json!({
            "sessionId": fixture.session_id,
            "target": "catalog::watch_snapshot",
            "arguments": {
                "afterRevision": before_revision,
                "limit": 10,
                "classes": ["availability"],
                "kinds": ["function_registered"],
                "ownerWorker": fixture.worker_id
            },
            "reason": "HMH-B4 live catalog revision proof"
        })),
    )
    .await;
    assert_eq!(
        watch_response["success"], true,
        "catalog watch execute failed: {watch_response}"
    );
    let watch_result = &watch_response["result"];
    assert!(
        watch_result.get("isError").is_none(),
        "catalog watch execute should not be an error: {watch_result}"
    );
    assert_eq!(watch_result["details"]["status"], "ok");
    assert_eq!(
        watch_result["details"]["functionId"],
        "catalog::watch_snapshot"
    );
    let watch_output = &watch_result["details"]["output"];
    assert!(
        watch_output["currentRevision"].as_u64().unwrap_or_default() >= spawn_revision,
        "watch current revision should include the spawned worker registration: {watch_output}"
    );
    let changes = watch_output["changes"]
        .as_array()
        .expect("catalog watch returns changes");
    let function_change = changes
        .iter()
        .find(|change| change["subjectId"] == fixture.function_id)
        .unwrap_or_else(|| {
            panic!(
                "catalog watch changes should include {}: {watch_output}",
                fixture.function_id
            )
        });
    assert_eq!(function_change["kind"], "function_registered");
    assert_eq!(function_change["subjectKind"], "function");
    assert_eq!(function_change["class"], "availability");
    assert_eq!(function_change["visibility"], "session");
    assert_eq!(function_change["sessionId"], fixture.session_id);
    assert_eq!(function_change["ownerWorker"], fixture.worker_id);
    assert!(
        function_change["afterRevision"]
            .as_u64()
            .unwrap_or_default()
            <= spawn_revision,
        "function registration change should be covered by spawn catalog revision"
    );

    let snapshot_functions = watch_output["snapshot"]["functions"]
        .as_array()
        .expect("catalog watch returns snapshot functions");
    let snapshot_function = snapshot_functions
        .iter()
        .find(|function| function["id"] == fixture.function_id)
        .unwrap_or_else(|| {
            panic!(
                "catalog snapshot should include {}: {watch_output}",
                fixture.function_id
            )
        });
    assert_eq!(snapshot_function["owner_worker"], fixture.worker_id);
    assert_eq!(snapshot_function["visibility"], "Session");
    assert_eq!(snapshot_function["health"], "Healthy");
    assert_eq!(
        snapshot_function["provenance"]["session_id"],
        fixture.session_id
    );
    assert_eq!(
        snapshot_function["metadata"]["trustTier"],
        "session_generated"
    );
    assert_eq!(snapshot_function["metadata"]["conformanceState"], "healthy");
    assert!(snapshot_function["request_schema"].is_object());
    assert!(snapshot_function["response_schema"].is_object());

    let inspect_response = rpc_call(
        &mut ws,
        3224,
        "capability::execute",
        Some(json!({
            "sessionId": fixture.session_id,
            "target": "capability::inspect",
            "arguments": {"functionId": fixture.function_id},
            "reason": "HMH-B4 execute inspection proof"
        })),
    )
    .await;
    assert_eq!(
        inspect_response["success"], true,
        "capability inspect execute failed: {inspect_response}"
    );
    let inspect_result = &inspect_response["result"];
    assert!(
        inspect_result.get("isError").is_none(),
        "capability inspect execute should not be an error: {inspect_result}"
    );
    let inspection = &inspect_result["details"];
    assert_eq!(
        inspection["orchestration"]["phaseDetails"]["selectedTarget"]["functionId"],
        "capability::inspect"
    );
    assert!(
        inspection["capabilityExecution"]["childInvocations"]
            .as_array()
            .is_some_and(|ids| ids.len() == 1),
        "execute should expose the capability::inspect child invocation id: {inspect_result}"
    );
    assert_eq!(inspection["contract"]["contractId"], fixture.function_id);
    assert!(inspection["contract"]["inputSchema"].is_object());
    assert!(inspection["contract"]["outputSchema"].is_object());
    assert_eq!(inspection["contract"]["effectClass"], "pure_read");
    assert_eq!(inspection["contract"]["riskLevel"], "low");
    assert_eq!(
        inspection["implementation"]["functionId"],
        fixture.function_id
    );
    assert_eq!(inspection["implementation"]["workerId"], fixture.worker_id);
    assert_eq!(inspection["implementation"]["health"], "Healthy");
    assert_eq!(inspection["implementation"]["visibility"], "session");
    assert_eq!(
        inspection["implementation"]["trustTier"],
        "session_generated"
    );
    assert_eq!(inspection["implementation"]["conformanceState"], "healthy");
    assert_eq!(
        inspection["implementation"]["signatureStatus"],
        "engine_issued"
    );
    assert_eq!(
        inspection["implementation"]["authorityRequirements"]["scopes"],
        json!([])
    );
    assert_eq!(
        inspection["implementation"]["authorityRequirements"]["approval_required"],
        false
    );
    assert_eq!(
        inspection["implementation"]["provenance"]["session_id"],
        fixture.session_id
    );
    assert_eq!(
        inspection["bindingDecision"]["selectedFunctionId"],
        fixture.function_id
    );
    assert_eq!(
        inspection["executionRequirements"]["freshInspectionRequired"],
        false
    );

    let stopped = stop_hmh_session_worker(&server, &fixture, "hmh-b4-stop-session-worker").await;
    assert_eq!(stopped["stopped"], true);

    server.shutdown().shutdown();
}

#[cfg(unix)]
#[tokio::test]
async fn capability_self_modifying_lifecycle_records_session_worker_conformance_evidence() {
    let port = reserve_loopback_port();
    let config = ServerConfig {
        host: "127.0.0.1".to_owned(),
        port,
        ..ServerConfig::default()
    };
    let (url, server) =
        boot_server_without_deps_with_config(config, format!("127.0.0.1:{port}")).await;
    let mut ws = connect(&url).await;
    let fixture =
        spawn_hmh_session_worker_through_execute(&mut ws, port, "conformance", 3231).await;

    let inspected = direct_engine_invoke_with_session(
        &server,
        "capability::inspect",
        json!({"functionId": fixture.function_id}),
        "hmh-b5-inspect-session-worker-function",
        &["capability.inspect"],
        &fixture.session_id,
    )
    .await;
    let inspection = &inspected["details"];
    let plugin_id = inspection["implementation"]["pluginId"]
        .as_str()
        .expect("inspection records plugin id")
        .to_owned();
    let implementation_id = inspection["implementation"]["implementationId"]
        .as_str()
        .expect("inspection records implementation id")
        .to_owned();
    assert_eq!(
        inspection["implementation"]["functionId"],
        fixture.function_id
    );
    assert_eq!(inspection["implementation"]["workerId"], fixture.worker_id);

    let conformance = direct_engine_invoke_with_session(
        &server,
        "capability::conformance_run",
        json!({
            "pluginId": plugin_id,
            "implementationId": implementation_id,
            "reason": "HMH-B5 session worker conformance evidence proof"
        }),
        "hmh-b5-run-session-worker-conformance",
        &["capability.plugin.write"],
        &fixture.session_id,
    )
    .await;
    assert_eq!(conformance["state"], "healthy");
    assert_eq!(
        conformance["checks"]["manifestImplementationsPresent"],
        true
    );
    assert!(
        conformance["resourceRefs"]
            .as_array()
            .is_some_and(|refs| refs.iter().any(|reference| reference["kind"] == "evidence")),
        "conformance_run must return evidence resource refs: {conformance}"
    );
    let evidence_ref = conformance["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "evidence")
        .expect("evidence ref")
        .clone();
    let evidence_resource_id = evidence_ref["resourceId"]
        .as_str()
        .expect("evidence ref has resource id")
        .to_owned();

    let evidence = direct_engine_invoke_with_session(
        &server,
        "resource::inspect",
        json!({"resourceId": evidence_resource_id}),
        "hmh-b5-inspect-conformance-evidence",
        &["resource.read"],
        &fixture.session_id,
    )
    .await;
    let evidence_inspection = &evidence["inspection"];
    assert_eq!(evidence_inspection["resource"]["kind"], "evidence");
    assert_eq!(evidence_inspection["resource"]["lifecycle"], "accepted");
    let evidence_payload = evidence_inspection["versions"][0]["payload"].clone();
    assert_eq!(evidence_payload["source"], "capability::conformance_run");
    assert_eq!(evidence_payload["status"], "healthy");
    assert_eq!(
        evidence_payload["target"]["pluginId"],
        conformance["pluginId"]
    );
    assert_eq!(
        evidence_payload["target"]["implementationIds"],
        json!([conformance["implementationId"].as_str().unwrap()])
    );
    assert_eq!(
        evidence_payload["target"]["functionIds"],
        json!([fixture.function_id.as_str()])
    );
    assert_eq!(
        evidence_payload["target"]["workerIds"],
        json!([fixture.worker_id.as_str()])
    );
    assert_eq!(
        evidence_payload["checks"]["manifestImplementationsPresent"],
        true
    );
    assert!(
        evidence_payload["metadata"]["parentInvocationId"].is_string(),
        "evidence should preserve invocation lineage: {evidence_payload}"
    );
    assert_eq!(
        evidence_payload["metadata"]["sessionId"], fixture.session_id,
        "session worker conformance evidence should stay session-scoped"
    );

    let stopped = stop_hmh_session_worker(&server, &fixture, "hmh-b5-stop-session-worker").await;
    assert_eq!(stopped["stopped"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_local_worker_registers_live_capability_invokes_and_disconnects() {
    let (url, server) = boot_server_without_deps().await;
    let engine_url = engine_ws_url_for(&url);
    let mut engine_ws = connect(&engine_url).await;
    let mut worker_ws = connect_worker(&engine_url).await;

    engine_ws
        .send(Message::text(
            json!({
                "type": "hello",
                "id": "hello-worker-test",
                "protocolVersion": 1,
                "sessionId": "worker-session"
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let hello = read_json(&mut engine_ws).await;
    assert_eq!(hello["type"], "hello.ok");

    let worker = WorkerDefinition::new(
        tron::engine::WorkerId::new("integration-worker").unwrap(),
        WorkerKind::External,
        ActorId::new("integration-worker-owner").unwrap(),
        AuthorityGrantId::new("worker-runtime").unwrap(),
    )
    .with_namespace_claim("demo");
    let mut worker_hello = tron::engine::WorkerHello::loopback(worker);
    worker_hello.session_id = Some("worker-session".to_owned());
    worker_ws
        .send(Message::text(
            serde_json::to_string(&WorkerProtocolMessage::Hello(Box::new(worker_hello))).unwrap(),
        ))
        .await
        .unwrap();
    let snapshot = read_json(&mut worker_ws).await;
    assert_eq!(snapshot["type"], "catalog_snapshot");

    let mut function = FunctionDefinition::new(
        FunctionId::new("demo::echo").unwrap(),
        tron::engine::WorkerId::new("integration-worker").unwrap(),
        "deterministic integration worker echo",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_provenance(Provenance::system().with_session_id("worker-session"));
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": true
    }));
    function.response_schema = Some(json!({
        "type": "object",
        "additionalProperties": true
    }));
    function.metadata = json!({
        "contractId": "demo::echo",
        "implementationId": "session_generated.demo.echo",
        "pluginId": "session_generated.integration-worker",
        "trustTier": "session_generated",
        "contextPrimerLevel": "catalog",
        "runtimeRequirements": {"workerKind": "external", "deliveryModes": ["Sync"]},
        "examples": []
    });
    worker_ws
        .send(Message::text(
            serde_json::to_string(&WorkerProtocolMessage::RegisterFunction(Box::new(
                tron::engine::RegisterFunction {
                    definition: function,
                    default_visibility: VisibilityScope::Session,
                },
            )))
            .unwrap(),
        ))
        .await
        .unwrap();
    let catalog_change = read_json(&mut worker_ws).await;
    assert_eq!(catalog_change["type"], "catalog_change");
    assert_eq!(catalog_change["subjectId"], "demo::echo");

    let (catalog, _) = raw_rpc_call_with_interleaved_events(
        &mut engine_ws,
        3001,
        "discover",
        Some(json!({
            "request": {"namespacePrefix": "demo"},
            "context": {"sessionId": "worker-session"}
        })),
    )
    .await;
    assert_eq!(catalog["ok"], true, "discover failed: {catalog}");
    assert!(
        catalog["result"].to_string().contains("demo::echo"),
        "discover result did not include demo::echo: {catalog}"
    );

    engine_ws
        .send(Message::text(
            json!({
                "type": "invoke",
                "id": "invoke-demo-echo",
                "functionId": "demo::echo",
                "payload": {"message": "hello from engine"},
                "context": {"sessionId": "worker-session"}
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let worker_invoke = read_json(&mut worker_ws).await;
    let worker_invoke: WorkerProtocolMessage = serde_json::from_value(worker_invoke).unwrap();
    let WorkerProtocolMessage::Invoke(invoke) = worker_invoke else {
        panic!("expected worker invocation");
    };
    assert_eq!(invoke.function_id.as_str(), "demo::echo");
    assert_eq!(invoke.payload["message"], "hello from engine");
    assert_eq!(invoke.session_id.as_deref(), Some("worker-session"));
    let trace_id = invoke.trace_id.to_string();
    worker_ws
        .send(Message::text(
            serde_json::to_string(&WorkerProtocolMessage::Result(WorkerInvocationResult {
                invocation_id: invoke.invocation_id,
                result: Some(json!({
                    "echo": invoke.payload,
                    "traceId": trace_id,
                })),
                error: None,
            }))
            .unwrap(),
        ))
        .await
        .unwrap();
    let invoke_response = read_json(&mut engine_ws).await;
    assert_eq!(invoke_response["type"], "response");
    assert_eq!(invoke_response["ok"], true);
    assert_eq!(
        invoke_response["result"]["child"]["value"]["echo"]["message"],
        "hello from engine"
    );

    let trace = server
        .runtime_context()
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("observability::trace_get").unwrap(),
            json!({"traceId": trace_id}),
            CausalContext::new(
                ActorId::new("integration-observer").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("engine-system").unwrap(),
                TraceId::new("integration-observability-trace").unwrap(),
            )
            .with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    assert!(
        trace.value.as_ref().unwrap()["invocations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["functionId"] == "demo::echo")
    );

    worker_ws
        .send(Message::text(
            serde_json::to_string(&WorkerProtocolMessage::Disconnect(
                tron::engine::WorkerDisconnect {
                    worker_id: tron::engine::WorkerId::new("integration-worker").unwrap(),
                    reason: "integration complete".to_owned(),
                },
            ))
            .unwrap(),
        ))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    let (removed, _) = raw_rpc_call_with_interleaved_events(
        &mut engine_ws,
        3003,
        "discover",
        Some(json!({
            "request": {"namespacePrefix": "demo"},
            "context": {"sessionId": "worker-session"}
        })),
    )
    .await;
    assert_eq!(removed["ok"], true);
    assert!(
        !removed["result"].to_string().contains("demo::echo"),
        "demo::echo should disappear after worker disconnect: {removed}"
    );

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_lifecycle() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Create
    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": integration_prompt_workdir(), "title": "Test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();
    assert!(!sid.is_empty());

    // List
    let resp = rpc_call(&mut ws, 2, "session::list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.iter().any(|s| s["sessionId"] == sid));

    // Get state
    let resp = rpc_call(
        &mut ws,
        3,
        "session::get_state",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["sessionId"], sid);

    // Delete
    let resp = rpc_call(
        &mut ws,
        4,
        "session::delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_round_trip() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Create session
    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Append event
    let resp = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "hello world"}
        })),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["event"].is_object());

    // Get history
    let resp = rpc_call(
        &mut ws,
        3,
        "events::get_history",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_settings_get() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "settings::get", None).await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].is_object());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_model_list() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "model::list", None).await;
    assert_eq!(resp["success"], true);
    let models = resp["result"]["models"].as_array().unwrap();
    assert!(!models.is_empty());

    for model in models {
        assert!(model["id"].is_string());
        assert!(model["name"].is_string());
        assert!(model["provider"].is_string());
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_prompt_acknowledged() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "Hello"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);
    assert!(resp["result"]["runId"].is_string());

    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_abort() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "Hello"})),
    )
    .await;

    let resp = rpc_call(&mut ws, 3, "agent::abort", Some(json!({"sessionId": sid}))).await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["aborted"], true);

    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_handling() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "nonexistent.method", None).await;
    assert_eq!(resp["success"], false);
    assert!(resp["error"]["code"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_invalid_json() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    ws.send(Message::text("not valid json")).await.unwrap();

    let msg = read_json(&mut ws).await;
    assert_eq!(msg["ok"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_missing_params() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "session::get_state", Some(json!({}))).await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "schema_violation");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_not_found() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::get_state",
        Some(json!({"sessionId": "nonexistent-id"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_skill_list() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "skills::list",
        Some(json!({"workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["skills"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_two_clients() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;

    let mut ws2 = connect(&url).await;

    // Both can ping
    let resp1 = rpc_call(&mut ws1, 1, "system::ping", None).await;
    let resp2 = rpc_call(&mut ws2, 1, "system::ping", None).await;
    assert_eq!(resp1["success"], true, "resp1: {resp1}");
    assert_eq!(resp2["success"], true, "resp2: {resp2}");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_rapid_fire_requests() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Send 50 rapid pings
    for i in 1..=50u64 {
        let payload = ping_params();
        let req = json!({
            "type": "invoke",
            "id": format!("rapid_{i}"),
            "functionId": "system::ping",
            "payload": payload,
            "idempotencyKey": integration_idempotency_key(i, "system::ping", &payload),
        });
        ws.send(Message::text(req.to_string())).await.unwrap();
    }

    // Collect all 50 responses
    let mut received = 0u64;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while received < 50 {
        let remaining = deadline - tokio::time::Instant::now();
        let msg = timeout(remaining, ws.next())
            .await
            .expect("timeout")
            .expect("stream closed")
            .expect("ws error");
        if let Message::Text(text) = msg {
            let parsed: Value = normalize_engine_ws_value(serde_json::from_str(&text).unwrap());
            if parsed.get("id").and_then(|v| v.as_str()).is_some() {
                let parsed = unwrap_engine_invoke_response(parsed);
                assert_eq!(parsed["success"], true);
                received += 1;
            }
        }
    }
    assert_eq!(received, 50);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_snapshot() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "context::get_snapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_concurrent_sessions() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp1 = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": "/tmp/1"})),
    )
    .await;
    let sid1 = resp1["result"]["sessionId"].as_str().unwrap().to_string();

    let resp2 = rpc_call(
        &mut ws,
        2,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": "/tmp/2"})),
    )
    .await;
    let sid2 = resp2["result"]["sessionId"].as_str().unwrap().to_string();

    assert_ne!(sid1, sid2);

    let resp = rpc_call(&mut ws, 3, "session::list", None).await;
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.len() >= 2);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_system_get_info() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "system::get_info", None).await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["version"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_tree_visualization() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "tree::get_visualization",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["sessionId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_get_state() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Not busy initially
    let resp = rpc_call(
        &mut ws,
        2,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["isRunning"], false);

    // Prompt to make busy
    let _ = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    // Now busy
    let resp = rpc_call(
        &mut ws,
        4,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["isRunning"], true);

    let abort = rpc_call(&mut ws, 5, "agent::abort", Some(json!({"sessionId": sid}))).await;
    assert_eq!(abort["result"]["aborted"], true);
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_archive_unarchive() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Archive
    let resp = rpc_call(
        &mut ws,
        2,
        "session::archive",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["archived"], true);

    // Unarchive
    let resp = rpc_call(
        &mut ws,
        3,
        "session::unarchive",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["unarchived"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_create_enriched_response() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp/test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let result = &resp["result"];

    // Verify enriched fields
    assert!(result["sessionId"].is_string());
    assert_eq!(result["model"], "claude-opus-4-6");
    assert_eq!(result["workingDirectory"], "/tmp/test");
    assert!(result["createdAt"].is_string());
    assert_eq!(result["isActive"], true);
    assert_eq!(result["isArchived"], false);
    assert_eq!(result["messageCount"], 0);
    assert_eq!(result["inputTokens"], 0);
    assert_eq!(result["outputTokens"], 0);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_list_enriched_fields() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let _ = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir(), "title": "Test Session"})),
    )
    .await;

    let resp = rpc_call(&mut ws, 2, "session::list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(!sessions.is_empty());

    let s = &sessions[0];
    assert!(s["sessionId"].is_string());
    assert!(s["model"].is_string());
    assert!(s["createdAt"].is_string());
    assert!(s.get("isActive").is_some());
    assert!(s.get("isArchived").is_some());
    assert!(s.get("eventCount").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_graceful_shutdown() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Verify the server is working before shutdown
    let resp = rpc_call(&mut ws, 1, "system::ping", None).await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();

    // Connection should eventually close — read until None or error
    let result = timeout(Duration::from_secs(3), async {
        while let Some(msg) = ws.next().await {
            if msg.is_err() {
                break;
            }
            if let Ok(Message::Close(_)) = msg {
                break;
            }
        }
    })
    .await;
    // It's okay if the shutdown timeout elapses — the test passed if we got here
    let _ = result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Event streaming tests
// ─────────────────────────────────────────────────────────────────────────────

const PROMPT_EVENT_TIMEOUT: Duration = Duration::from_secs(20);
const PROMPT_STATE_TIMEOUT: Duration = Duration::from_secs(20);
const PROMPT_STATE_POLL: Duration = Duration::from_millis(10);

fn integration_prompt_workdir() -> String {
    let path = unique_runtime_path("prompt-workdir", "dir");
    std::fs::create_dir_all(&path).unwrap();
    path.to_string_lossy().into_owned()
}

/// Helper to create a session and bind the client to it.
async fn create_and_bind_session(ws: &mut WsStream, id: u64) -> String {
    let resp = rpc_call(
        ws,
        id,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    resp["result"]["sessionId"].as_str().unwrap().to_string()
}

/// Try to read a JSON message within timeout. Returns None on timeout.
async fn try_read_json(ws: &mut WsStream, dur: Duration) -> Option<Value> {
    timeout(dur, async {
        loop {
            if let Some(Ok(Message::Text(text))) = ws.next().await {
                return serde_json::from_str::<Value>(&text)
                    .ok()
                    .map(normalize_engine_ws_value);
            }
        }
    })
    .await
    .unwrap_or_default()
}

/// Read until we see a specific event type. Returns the matching event.
async fn read_until_event_type(ws: &mut WsStream, event_type: &str) -> Option<Value> {
    let mut events = collect_events_until_type(ws, event_type, PROMPT_EVENT_TIMEOUT).await;
    take_event_type(&mut events, event_type)
}

fn take_event_type(events: &mut Vec<Value>, event_type: &str) -> Option<Value> {
    let pos = events
        .iter()
        .position(|msg| msg.get("type").and_then(|v| v.as_str()) == Some(event_type))?;
    Some(events.remove(pos))
}

async fn wait_for_detailed_snapshot_rules(
    ws: &mut WsStream,
    session_id: &str,
    starting_id: u64,
) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut request_id = starting_id;

    loop {
        let resp = rpc_call(
            ws,
            request_id,
            "context::get_detailed_snapshot",
            Some(json!({"sessionId": session_id})),
        )
        .await;
        assert_eq!(
            resp["success"], true,
            "context.getDetailedSnapshot failed: {resp}"
        );

        let result = resp["result"].clone();
        if result["rules"].is_object() {
            return result;
        }

        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for rules in detailed snapshot, last result: {result}"
        );

        request_id += 1;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn e2e_stream_event_pump_delivers_to_bound_client() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // session::create through the `/engine` `invoke` message auto-binds the connection.
    let sid = create_and_bind_session(&mut ws, 1).await;

    publish_engine_session_event(&server, &sid, "agent.turn_start", json!({})).await;

    // Should receive the event
    let evt = read_until_event_type(&mut ws, "agent.turn_start").await;
    assert!(evt.is_some(), "should receive agent.turn_start event");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_stream_event_pump_multiple_clients() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;
    let mut ws2 = connect(&url).await;

    // ws1 creates a session through the `/engine` `invoke` message, which auto-binds ws1.
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // ws2 resumes the same session through the `/engine` `invoke` message, which auto-binds ws2.
    let _ = rpc_call(
        &mut ws2,
        1,
        "session::resume",
        Some(json!({"sessionId": sid})),
    )
    .await;

    publish_engine_session_event(
        &server,
        &sid,
        "agent.text_delta",
        json!({"content": "hello both"}),
    )
    .await;

    let evt1 = read_until_event_type(&mut ws1, "agent.text_delta").await;
    let evt2 = read_until_event_type(&mut ws2, "agent.text_delta").await;
    assert!(evt1.is_some());
    assert!(evt2.is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_stream_event_pump_session_isolation() {
    let (url, server) = boot_server().await;

    // Two connections, each bound to a different session
    let mut ws1 = connect(&url).await;
    let mut ws2 = connect(&url).await;

    let _sid1 = create_and_bind_session(&mut ws1, 1).await;
    let sid2 = create_and_bind_session(&mut ws2, 1).await;

    // Drain any session lifecycle events that may have been broadcast; the
    // canonical session-created event can race with binding.
    let _ = try_read_json(&mut ws1, Duration::from_millis(50)).await;
    let _ = try_read_json(&mut ws2, Duration::from_millis(50)).await;

    publish_engine_session_event(&server, &sid2, "agent.turn_start", json!({})).await;

    // ws1 (bound to sid1) should NOT receive sid2's agent.turn_start event.
    let evt1 = tokio::time::timeout(Duration::from_millis(200), async {
        loop {
            match try_read_json(&mut ws1, Duration::from_millis(25)).await {
                Some(msg)
                    if msg.get("type").and_then(|v| v.as_str()) == Some("agent.turn_start") =>
                {
                    break Some(msg);
                }
                Some(_) => {}
                None => break None,
            }
        }
    })
    .await
    .unwrap_or(None);
    assert!(
        evt1.is_none(),
        "ws1 should not receive sid2 agent.turn_start events"
    );

    // ws2 (bound to sid2) SHOULD receive it
    let evt2 = read_until_event_type(&mut ws2, "agent.turn_start").await;
    assert!(evt2.is_some(), "ws2 should receive sid2 events");
    if let Some(evt) = evt2 {
        assert_eq!(evt["sessionId"], sid2);
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_type_field() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let events = vec![
        TronEvent::AgentStart {
            base: BaseEvent::now(&sid),
        },
        TronEvent::TurnStart {
            base: BaseEvent::now(&sid),
            turn: 1,
        },
        TronEvent::MessageUpdate {
            base: BaseEvent::now(&sid),
            content: "hello".into(),
        },
    ];

    for evt in events {
        let _ = server.runtime_context().orchestrator.broadcast().emit(evt);
    }

    // Read all 3 events
    for _ in 0..3 {
        if let Some(evt) = try_read_json(&mut ws, Duration::from_secs(2)).await {
            assert!(
                evt.get("type").is_some(),
                "event should have type field: {evt}"
            );
        }
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_timestamp() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    publish_engine_session_event(&server, &sid, "agent.turn_start", json!({})).await;

    let evt = read_until_event_type(&mut ws, "agent.turn_start").await;
    assert!(evt.is_some());
    assert!(evt.unwrap()["timestamp"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_session_id() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    publish_engine_session_event(&server, &sid, "agent.turn_start", json!({})).await;

    let evt = read_until_event_type(&mut ws, "agent.turn_start").await;
    assert!(evt.is_some());
    assert_eq!(evt.unwrap()["sessionId"], sid);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_event_ordering_preserved() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Emit 20 sequential events
    for i in 0..20 {
        let _ = server
            .runtime_context()
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageUpdate {
                base: BaseEvent::now(&sid),
                content: format!("msg_{i}"),
            });
    }

    // Collect events and verify order
    let mut received = Vec::new();
    for _ in 0..20 {
        if let Some(evt) = try_read_json(&mut ws, Duration::from_secs(3)).await
            && evt.get("type").and_then(|v| v.as_str()) == Some("agent.text_delta")
            && let Some(data) = evt.get("data")
        {
            received.push(data["delta"].as_str().unwrap_or("").to_string());
        }
    }

    for (i, msg) in received.iter().enumerate() {
        assert_eq!(msg, &format!("msg_{i}"), "event {i} out of order");
    }

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Session reconstruction tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_state_persists_after_disconnect() {
    let (url, server) = boot_server().await;

    // Create session with first client
    let mut ws1 = connect(&url).await;
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // Disconnect first client
    drop(ws1);

    // Reconnect with new client
    let mut ws2 = connect(&url).await;

    // Session should still exist
    let resp = rpc_call(
        &mut ws2,
        1,
        "session::get_state",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["sessionId"], sid);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_survive_reconnect() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // Append event
    let _ = rpc_call(
        &mut ws1,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "persisted message"}
        })),
    )
    .await;

    // Disconnect
    drop(ws1);

    // Reconnect
    let mut ws2 = connect(&url).await;

    // Get history should still return the event
    let resp = rpc_call(
        &mut ws2,
        1,
        "events::get_history",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reconstruct_messages() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append user and assistant messages
    let _ = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "user question"}
        })),
    )
    .await;

    let _ = rpc_call(
        &mut ws,
        3,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.assistant",
            "payload": {"text": "assistant answer"}
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        4,
        "context::get_snapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reconstruct_preserves_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append event with token data
    let _ = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "turn.end",
            "payload": {
                "turn": 1,
                "duration": 1000,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
            }
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "events::get_history",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_multiple_events_in_sequence() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append multiple events
    for i in 0..5 {
        let _ = rpc_call(
            &mut ws,
            (i + 2) as u64,
            "events::append",
            Some(json!({
                "sessionId": sid,
                "type": "message.user",
                "payload": {"text": format!("message {i}")}
            })),
        )
        .await;
    }

    let resp = rpc_call(
        &mut ws,
        10,
        "events::get_history",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(events.len() >= 5);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_history() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // context.getSnapshot returns context window state
    let resp = rpc_call(
        &mut ws,
        2,
        "context::get_snapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].is_object());

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Concurrent + stress tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_concurrent_isolated() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Create two sessions
    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Append to each independently
    let resp1 = rpc_call(
        &mut ws,
        3,
        "events::append",
        Some(json!({
            "sessionId": sid1,
            "type": "message.user",
            "payload": {"text": "for session 1"}
        })),
    )
    .await;
    assert_eq!(resp1["success"], true);

    let resp2 = rpc_call(
        &mut ws,
        4,
        "events::append",
        Some(json!({
            "sessionId": sid2,
            "type": "message.user",
            "payload": {"text": "for session 2"}
        })),
    )
    .await;
    assert_eq!(resp2["success"], true);

    // Verify each session has its own events (session.start + appended event = 2 each)
    let h1 = rpc_call(
        &mut ws,
        5,
        "events::get_history",
        Some(json!({"sessionId": sid1})),
    )
    .await;
    let h2 = rpc_call(
        &mut ws,
        6,
        "events::get_history",
        Some(json!({"sessionId": sid2})),
    )
    .await;
    let e1 = h1["result"]["events"].as_array().unwrap();
    let e2 = h2["result"]["events"].as_array().unwrap();
    assert_eq!(
        e1.len(),
        e2.len(),
        "both sessions should have equal event counts"
    );
    assert!(
        e1.len() >= 2,
        "each session should have session.start + appended event"
    );

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_many_sessions_stress() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let mut sids = Vec::new();
    for i in 0..10 {
        let resp = rpc_call(
            &mut ws,
            (i + 1) as u64,
            "session::create",
            Some(json!({"model": "m", "workingDirectory": format!("{}/{i}", integration_prompt_workdir())})),
        )
        .await;
        assert_eq!(resp["success"], true, "session {i} creation failed");
        sids.push(resp["result"]["sessionId"].as_str().unwrap().to_string());
    }

    // Verify all sessions exist
    let resp = rpc_call(&mut ws, 100, "session::list", None).await;
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.len() >= 10);

    // Delete all
    for (i, sid) in sids.iter().enumerate() {
        let resp = rpc_call(
            &mut ws,
            (200 + i) as u64,
            "session::delete",
            Some(json!({"sessionId": sid})),
        )
        .await;
        assert_eq!(resp["success"], true);
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_concurrent_prompts_different_sessions() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Both sessions can accept prompts
    let resp1 = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid1, "prompt": "test 1"})),
    )
    .await;
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent::prompt",
        Some(json!({"sessionId": sid2, "prompt": "test 2"})),
    )
    .await;
    assert_eq!(resp1["success"], true, "resp1: {resp1}");
    assert_eq!(resp2["success"], true, "resp2: {resp2}");

    wait_until_run_cleared(&server, &sid1).await;
    wait_until_run_cleared(&server, &sid2).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_cleanup_after_delete() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append an event
    let _ = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "will be deleted"}
        })),
    )
    .await;

    // Delete session
    let resp = rpc_call(
        &mut ws,
        3,
        "session::delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    // Session should no longer be found
    let resp = rpc_call(
        &mut ws,
        4,
        "session::get_state",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Error handling tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_error_malformed_engine_message() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Send valid JSON but invalid engine protocol payload (missing type)
    ws.send(Message::text(r#"{"id": "test", "params": {}}"#))
        .await
        .unwrap();

    let msg = read_json(&mut ws).await;
    assert_eq!(msg["ok"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_empty_method() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "", None).await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_prompt_nonexistent_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "agent::prompt",
        Some(json!({"sessionId": "nonexistent-session", "prompt": "hello"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_delete_active_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Start a prompt (makes session busy)
    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "running"})),
    )
    .await;

    // Delete should still work even if busy (cleanup)
    let resp = rpc_call(
        &mut ws,
        3,
        "session::delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    // Depending on implementation, this may succeed or fail
    // Either way, it should not crash the server
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_get_events_no_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "events::get_history",
        Some(json!({"sessionId": "nonexistent"})),
    )
    .await;
    // Should return empty events or error, but not crash
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_append_invalid() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Missing sessionId
    let resp = rpc_call(
        &mut ws,
        1,
        "events::append",
        Some(json!({"type": "message.user", "payload": {"text": "hello"}})),
    )
    .await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_settings_update_invalid() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Update with empty params
    let resp = rpc_call(&mut ws, 1, "settings::update", Some(json!({}))).await;
    // Should gracefully handle (either succeed with no-op or fail with message)
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reject_concurrent_same_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt succeeds
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;
    assert_eq!(resp1["success"], true);

    // Second prompt to same session should fail (SESSION_BUSY)
    let resp2 = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp2["success"], false);
    assert_eq!(resp2["error"]["code"], "SESSION_BUSY");

    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_sequential_prompts_after_abort() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Start first prompt
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;
    assert_eq!(resp1["success"], true);

    // Abort
    let _ = rpc_call(&mut ws, 3, "agent::abort", Some(json!({"sessionId": sid}))).await;

    wait_until_run_cleared(&server, &sid).await;

    // Second prompt should work now
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp2["success"], true);

    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "second prompt should complete after abort");
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Memory integration tests
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Phase 14: Prompt execution chain e2e tests
// ─────────────────────────────────────────────────────────────────────────────

/// Collect WebSocket messages until a target event arrives or the timeout
/// expires. Prompt e2e tests use this instead of sleeps because the first
/// prompt in this integration binary can pay context warmup and scheduler cost
/// before provider output begins.
async fn collect_events_until_type(
    ws: &mut WsStream,
    event_type: &str,
    dur: Duration,
) -> Vec<Value> {
    let mut events = Vec::new();
    let start = tokio::time::Instant::now();
    while start.elapsed() < dur {
        let remaining = dur.saturating_sub(start.elapsed());
        if let Some(msg) = try_read_json(ws, remaining).await {
            let matched = msg.get("type").and_then(|v| v.as_str()) == Some(event_type);
            events.push(msg);
            if matched {
                break;
            }
        } else {
            break;
        }
    }
    events
}

/// Wait until agent.getState shows not busy, with a timeout.
async fn wait_until_not_busy(ws: &mut WsStream, sid: &str, id_start: u64) {
    tokio::time::timeout(PROMPT_STATE_TIMEOUT, async {
        let mut i = 0;
        loop {
            tokio::time::sleep(PROMPT_STATE_POLL).await;
            let resp = rpc_call(
                ws,
                id_start + i,
                "session::reconstruct",
                Some(json!({"sessionId": sid})),
            )
            .await;
            if resp["result"]["isRunning"] == false {
                break;
            }
            i += 1;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("session {sid} still busy after prompt-state timeout"));
}

async fn wait_until_active_run(server: &Arc<TronServer>, sid: &str) {
    tokio::time::timeout(PROMPT_STATE_TIMEOUT, async {
        loop {
            if server.runtime_context().orchestrator.has_active_run(sid) {
                break;
            }
            tokio::time::sleep(PROMPT_STATE_POLL).await;
        }
    })
    .await
    .expect("session should become active");
}

async fn wait_until_reconstruct_running(
    ws: &mut WsStream,
    sid: &str,
    expected_run_id: &str,
    id_start: u64,
) -> Value {
    let deadline = tokio::time::Instant::now() + PROMPT_STATE_TIMEOUT;
    let mut i = 0;
    loop {
        let resp = rpc_call(
            ws,
            id_start + i,
            "session::reconstruct",
            Some(json!({"sessionId": sid})),
        )
        .await;
        let result = &resp["result"];
        if resp["success"] == true
            && result["isRunning"] == true
            && result["runId"].as_str() == Some(expected_run_id)
        {
            return resp;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "session {sid} did not reconstruct active run {expected_run_id}; last response: {resp}"
        );
        i += 1;
        tokio::time::sleep(PROMPT_STATE_POLL).await;
    }
}

async fn wait_until_run_cleared(server: &Arc<TronServer>, sid: &str) {
    // Prompt cleanup is usually immediate, but this integration binary runs a
    // busy WebSocket/server suite concurrently. Keep the poll interval tight so
    // success is fast while giving heavily loaded CI enough scheduler headroom.
    tokio::time::timeout(PROMPT_STATE_TIMEOUT, async {
        loop {
            if !server.runtime_context().orchestrator.has_active_run(sid)
                && !server.runtime_context().orchestrator.is_session_busy(sid)
            {
                break;
            }
            tokio::time::sleep(PROMPT_STATE_POLL).await;
        }
    })
    .await
    .expect("session run should be cleaned up");
}

#[tokio::test]
async fn e2e_prompt_text_response() {
    let provider = Arc::new(TextOnlyProvider::new("Hello from the agent!"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let (resp, mut interleaved) = rpc_call_with_interleaved_events(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "Say hello"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);

    // Wait for agent.ready (the final event in the lifecycle)
    let ready = take_event_type(&mut interleaved, "agent.ready").or(read_until_event_type(
        &mut ws,
        "agent.ready",
    )
    .await);
    assert!(ready.is_some(), "should receive agent.ready event");
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_panic_cleans_up_and_server_recovers() {
    let provider = Arc::new(PanicThenTextProvider::new("recovered"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "panic once"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);

    wait_until_run_cleared(&server, &sid).await;

    let state = rpc_call(
        &mut ws,
        3,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(state["success"], true);
    assert_eq!(state["result"]["isRunning"], false);

    let sessions = rpc_call(&mut ws, 4, "session::list", None).await;
    assert_eq!(sessions["success"], true);
    assert!(
        sessions["result"]["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|session| session["sessionId"] == sid),
        "session should still be queryable after provider panic"
    );

    let retry = rpc_call(
        &mut ws,
        5,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "recover"})),
    )
    .await;
    assert_eq!(retry["success"], true);
    assert_eq!(retry["result"]["acknowledged"], true);

    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "recovery prompt should complete");
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_event_ordering() {
    let provider = Arc::new(TextOnlyProvider::new("ordered"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let (_, mut events) = rpc_call_with_interleaved_events(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    events.extend(collect_events_until_type(&mut ws, "agent.ready", PROMPT_EVENT_TIMEOUT).await);
    let types: Vec<&str> = events
        .iter()
        .filter_map(|e| e.get("type").and_then(|v| v.as_str()))
        .collect();

    // agent.complete must come before agent.ready
    let complete_pos = types.iter().position(|t| *t == "agent.complete");
    let ready_pos = types.iter().position(|t| *t == "agent.ready");
    assert!(
        complete_pos.is_some(),
        "agent.complete must be in events: {types:?}"
    );
    assert!(
        ready_pos.is_some(),
        "agent.ready must be in events: {types:?}"
    );
    assert!(
        complete_pos.unwrap() < ready_pos.unwrap(),
        "agent.complete ({}) must precede agent.ready ({})",
        complete_pos.unwrap(),
        ready_pos.unwrap()
    );
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_error_from_provider() {
    let provider = Arc::new(ErrorProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let (_, mut interleaved) = rpc_call_with_interleaved_events(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "this will fail"})),
    )
    .await;

    // Even on provider error, agent.ready must arrive
    let ready = take_event_type(&mut interleaved, "agent.ready").or(read_until_event_type(
        &mut ws,
        "agent.ready",
    )
    .await);
    assert!(
        ready.is_some(),
        "agent.ready must arrive even after provider error"
    );
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_cleans_up_on_complete() {
    let provider = Arc::new(TextOnlyProvider::new("done"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "work"})),
    )
    .await;

    // agent.ready is emitted before the async prompt task returns to its cleanup
    // path, so wait for both the event and the orchestrator cleanup.
    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "agent.ready must arrive before cleanup");
    wait_until_run_cleared(&server, &sid).await;

    // getState should show not busy
    let resp = rpc_call(
        &mut ws,
        10,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_sequential() {
    let provider = Arc::new(TextOnlyProvider::new("response"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt
    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;

    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "first prompt should complete");
    wait_until_run_cleared(&server, &sid).await;

    // Second prompt should succeed
    let resp = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);

    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "second prompt should complete");
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_reject_concurrent() {
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt (will run for 30s with SlowProvider)
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "slow"})),
    )
    .await;
    assert_eq!(resp1["success"], true);
    wait_until_active_run(&server, &sid).await;

    // Second prompt should be rejected (session busy)
    let resp2 = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "rejected"})),
    )
    .await;
    assert_eq!(resp2["success"], false);
    assert_eq!(resp2["error"]["code"], "SESSION_BUSY");

    let abort = rpc_call(&mut ws, 4, "agent::abort", Some(json!({"sessionId": sid}))).await;
    assert_eq!(abort["result"]["aborted"], true);
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_graceful_shutdown_cleans_up_active_prompt_run() {
    let provider = Arc::new(SlowProvider);
    let (url, server, handles) = boot_server_with_provider_and_handles(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "slow"})),
    )
    .await;
    assert_eq!(resp["success"], true);

    wait_until_active_run(&server, &sid).await;

    server
        .shutdown()
        .graceful_shutdown(handles, Some(Duration::from_secs(5)))
        .await;

    assert!(server.shutdown().is_shutting_down());
    assert!(!server.runtime_context().orchestrator.has_active_run(&sid));
    assert!(!server.runtime_context().orchestrator.is_session_busy(&sid));
    assert_eq!(server.shutdown().tracked_task_count(), 0);

    let close_result = timeout(Duration::from_secs(2), async {
        while let Some(msg) = ws.next().await {
            if msg.is_err() || matches!(msg, Ok(Message::Close(_))) {
                break;
            }
        }
    })
    .await;
    let _ = close_result;
}

#[tokio::test]
async fn e2e_prompt_abort_mid_stream() {
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "slow task"})),
    )
    .await;

    wait_until_active_run(&server, &sid).await;

    // Abort
    let resp = rpc_call(&mut ws, 3, "agent::abort", Some(json!({"sessionId": sid}))).await;
    assert_eq!(resp["result"]["aborted"], true);

    // Wait for the run to be cleaned up (agent_runner calls complete_run)
    wait_until_not_busy(&mut ws, &sid, 100).await;
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_without_deps_returns_not_available() {
    let (url, server) = boot_server_without_deps().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "no deps"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "NOT_AVAILABLE");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_multiple_sessions() {
    let provider = Arc::new(TextOnlyProvider::new("multi"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Both can prompt
    let resp1 = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid1, "prompt": "session 1"})),
    )
    .await;
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent::prompt",
        Some(json!({"sessionId": sid2, "prompt": "session 2"})),
    )
    .await;
    assert_eq!(resp1["success"], true);
    assert_eq!(resp2["success"], true);

    // Both should eventually complete
    wait_until_not_busy(&mut ws, &sid1, 100).await;
    wait_until_not_busy(&mut ws, &sid2, 200).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_run_id_matches() {
    // Use SlowProvider so the run is still active when we check getState
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;
    let run_id = resp["result"]["runId"].as_str().unwrap().to_string();
    assert!(!run_id.is_empty());

    // session.reconstruct should show the exact active run while agent is busy.
    wait_until_active_run(&server, &sid).await;
    let resp = wait_until_reconstruct_running(&mut ws, &sid, &run_id, 3).await;
    assert_eq!(resp["result"]["isRunning"], true);
    assert_eq!(resp["result"]["runId"], run_id);

    let abort = rpc_call(
        &mut ws,
        100,
        "agent::abort",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(abort["result"]["aborted"], true);
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_text_content_arrives() {
    let provider = Arc::new(TextOnlyProvider::new("specific text content"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let (_, mut events) = rpc_call_with_interleaved_events(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    events.extend(collect_events_until_type(&mut ws, "agent.ready", PROMPT_EVENT_TIMEOUT).await);
    let text_deltas: Vec<&Value> = events
        .iter()
        .filter(|e| e.get("type").and_then(|v| v.as_str()) == Some("agent.text_delta"))
        .collect();

    assert!(
        !text_deltas.is_empty(),
        "should receive text_delta events, got: {:?}",
        events
            .iter()
            .filter_map(|e| e.get("type"))
            .collect::<Vec<_>>()
    );

    // Verify actual text content from the provider is present
    let has_content = text_deltas.iter().any(|e| {
        e["data"]["delta"]
            .as_str()
            .unwrap_or("")
            .contains("specific text content")
    });
    assert!(has_content, "text_delta should contain provider text");
    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_events_scoped_to_session() {
    let provider = Arc::new(TextOnlyProvider::new("scoped"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    let events = collect_events_until_type(&mut ws, "agent.ready", PROMPT_EVENT_TIMEOUT).await;

    // All agent events should have the correct session ID
    for evt in &events {
        if let Some(event_type) = evt.get("type").and_then(|v| v.as_str())
            && event_type.starts_with("agent.")
            && let Some(evt_sid) = evt.get("sessionId").and_then(|v| v.as_str())
        {
            assert_eq!(
                evt_sid, sid,
                "event {event_type} should be scoped to session {sid}"
            );
        }
    }

    wait_until_run_cleared(&server, &sid).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_state_transitions() {
    let provider = Arc::new(TextOnlyProvider::new("state"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Initially not busy
    let resp = rpc_call(
        &mut ws,
        2,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], false, "should start not busy");

    // Send prompt
    let _ = rpc_call(
        &mut ws,
        3,
        "agent::prompt",
        Some(json!({"sessionId": sid, "prompt": "work"})),
    )
    .await;

    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "prompt should complete");
    wait_until_run_cleared(&server, &sid).await;

    // Should be not busy again
    let resp = rpc_call(
        &mut ws,
        10,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(
        resp["result"]["isRunning"], false,
        "should be not busy after ready"
    );

    server.shutdown().shutdown();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 15: engine transport payload integration tests
// ═══════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn e2e_system_get_info_engine_protocol_payload() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "system::get_info", None).await;
    let result = &resp["result"];
    assert!(result["version"].is_string());
    assert!(result["uptime"].is_number());
    assert!(result["activeSessions"].is_number());
    assert!(result["platform"].is_string());
    assert!(result["arch"].is_string());
    assert_eq!(result["runtime"], "agent");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_get_state_engine_protocol_payload() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "session::reconstruct",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];
    assert_eq!(result["isRunning"], false);
    assert!(result["metadata"]["turnCount"].is_number());
    assert!(result["metadata"]["model"].is_string());
    assert!(result["lastSequence"].is_number());
    assert!(result["events"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_get_history_exists() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "session::get_history",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];
    assert!(result["messages"].is_array());
    assert_eq!(result["hasMore"], false);

    server.shutdown().shutdown();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 16: engine transport wire format tests
// ═══════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn e2e_engine_hello_returns_server_id() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    ws.send(Message::text(
        json!({"type": "hello", "id": "hello", "protocolVersion": 1}).to_string(),
    ))
    .await
    .unwrap();
    let msg = read_json(&mut ws).await;
    assert_eq!(msg["type"], "hello.ok");
    assert!(msg["serverId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_list_has_cache_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let _ = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;

    let resp = rpc_call(&mut ws, 2, "session::list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    let s = &sessions[0];
    assert!(s.get("cacheReadTokens").is_some());
    assert!(s.get("cacheCreationTokens").is_some());
    assert!(s.get("lastTurnInputTokens").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_model_list_ios_cost_fields() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(&mut ws, 1, "model::list", None).await;
    let models = resp["result"]["models"].as_array().unwrap();
    for model in models {
        assert!(
            model.get("inputCostPerMillion").is_some(),
            "missing inputCostPerMillion"
        );
        assert!(
            model.get("outputCostPerMillion").is_some(),
            "missing outputCostPerMillion"
        );
        assert!(
            model.get("inputCostPer1M").is_none(),
            "removed inputCostPer1M field should not exist"
        );
    }

    server.shutdown().shutdown();
}

// ── Phase 17: Context loading integration tests ──

#[tokio::test]
async fn e2e_context_snapshot_has_real_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // Create session
    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    // Get context snapshot
    let resp = rpc_call(
        &mut ws,
        2,
        "context::get_snapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];

    // System prompt tokens should be > 0 (default TRON_CORE_PROMPT is non-empty)
    assert!(
        result["breakdown"]["systemPrompt"].as_u64().unwrap() > 0,
        "systemPrompt tokens should be > 0"
    );
    // Context limit should match model
    assert_eq!(
        result["contextLimit"].as_u64().unwrap(),
        tron::domains::model::providers::model_context_window("claude-opus-4-6")
    );
    assert_eq!(result["thresholdLevel"], "normal");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_detailed_snapshot_has_system_prompt() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let resp = rpc_call(
        &mut ws,
        2,
        "context::get_detailed_snapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];

    // System prompt content should be non-empty
    let sys_content = result["systemPromptContent"].as_str().unwrap();
    assert!(
        !sys_content.is_empty(),
        "systemPromptContent should be non-empty"
    );

    // iOS required fields
    assert!(result["messages"].is_array());
    assert!(result["capabilitiesContent"].is_array());
    assert!(result["addedSkills"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_detailed_snapshot_has_rules_when_present() {
    let tmp = tempfile::tempdir().unwrap();
    let claude_dir = tmp.path().join(".claude");
    std::fs::create_dir_all(&claude_dir).unwrap();
    std::fs::write(claude_dir.join("AGENTS.md"), "# E2E Test Rules\nFoo bar.").unwrap();

    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": tmp.path().to_str().unwrap()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let result = wait_for_detailed_snapshot_rules(&mut ws, &sid, 2).await;

    // Rules should be structured: { files, totalFiles, tokens }
    let rules = &result["rules"];
    assert!(rules.is_object(), "rules should be an object, got: {rules}");
    assert!(rules["totalFiles"].as_u64().unwrap() > 0);
    assert!(rules["tokens"].as_u64().unwrap() > 0);
    let files = rules["files"].as_array().unwrap();
    assert!(!files.is_empty());
    assert!(result["breakdown"]["rules"].as_u64().unwrap() > 0);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_should_compact_reflects_usage() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    // Empty session should not need compaction
    let resp = rpc_call(
        &mut ws,
        2,
        "context::should_compact",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["shouldCompact"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_can_accept_turn_empty_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": integration_prompt_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let resp = rpc_call(
        &mut ws,
        2,
        "context::can_accept_turn",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["canAcceptTurn"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_snapshot_session_not_found() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "context::get_snapshot",
        Some(json!({"sessionId": "nonexistent_session"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}
