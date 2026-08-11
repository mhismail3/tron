use super::*;

#[tokio::test]
async fn resident_service_starts_lazily_and_handles_multiple_calls() {
    let (runtime, home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let escaped_descendant = home.path().join("resident-descendant-escaped");
    let script = r#"import http.server,json,subprocess,sys
subprocess.Popen([sys.executable,'-c','import os,pathlib,sys,time; parent=os.getppid();\nwhile os.getppid()==parent: time.sleep(.01)\npathlib.Path(sys.argv[1]).write_text(\"escaped\")',sys.argv[2]])
open('service-runtime-only.txt','w').write('runtime')
sys.stderr.write('resident startup log\n'*200000); sys.stderr.flush()
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(n)
  value=json.loads(body); value['idempotencyKey']=self.headers.get('x-tron-idempotency-key'); value['traceId']=self.headers.get('x-tron-trace-id')
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(value).encode())
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Resident Echo".to_owned();
    bundle.description = "Lazy supervised resident HTTP echo service".to_owned();
    bundle.tool_name = Some("worker_resident_echo".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script.to_owned(),
            port.to_string(),
            escaped_descendant.display().to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    assert!(runtime.residents.is_empty());
    for index in 0..2 {
        let result = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"index":index}),
                &format!("service-{index}"),
            ))
            .await
            .unwrap();
        assert_eq!(
            result.output,
            Some(json!({
                "index":index,
                "idempotencyKey":format!("service-{index}"),
                "traceId":format!("trace-service-{index}"),
            }))
        );
    }
    assert_eq!(runtime.residents.len(), 1);
    assert!(
        !home
            .path()
            .join("workspace/workers")
            .join(&outcome.worker.worker_id)
            .join("versions")
            .join(&outcome.version)
            .join("files/service-runtime-only.txt")
            .exists(),
        "resident service mutated its immutable canonical version"
    );

    runtime.set_stop_all(true).await.unwrap();
    assert!(runtime.residents.is_empty());
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        !escaped_descendant.exists(),
        "resident descendant survived stop-all"
    );
    runtime.set_stop_all(false).await.unwrap();
    let resumed = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"index":2}),
            "service-after-stop-all",
        ))
        .await
        .unwrap();
    assert_eq!(resumed.output.as_ref().unwrap()["index"], 2);
    assert_eq!(runtime.residents.len(), 1);
    assert!(!escaped_descendant.exists());

    runtime
        .set_enabled(&outcome.worker.worker_id, false)
        .await
        .unwrap();
    assert!(runtime.residents.is_empty());
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        !escaped_descendant.exists(),
        "resident descendant survived disable"
    );
    runtime
        .set_enabled(&outcome.worker.worker_id, true)
        .await
        .unwrap();
    let enabled = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"index":3}),
            "service-after-enable",
        ))
        .await
        .unwrap();
    assert_eq!(enabled.output.as_ref().unwrap()["index"], 3);
    assert_eq!(runtime.residents.len(), 1);
    assert!(!escaped_descendant.exists());

    runtime.shutdown().await;
    assert!(runtime.residents.is_empty());
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        !escaped_descendant.exists(),
        "resident descendant survived runtime shutdown"
    );
}

#[tokio::test]
async fn ready_resident_reuses_its_verified_snapshot_but_restart_reverifies_canonical_state() {
    let (runtime, home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let script = r#"import http.server,json,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); value=json.loads(self.rfile.read(n))
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(value).encode())
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("resident-verified-snapshot".to_owned());
    bundle.name = "Resident Verified Snapshot".to_owned();
    bundle.tool_name = Some("worker_resident_verified_snapshot".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script.to_owned(),
            port.to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let first = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"value":1}),
            "resident-snapshot-first",
        ))
        .await
        .unwrap();
    assert_eq!(first.output.unwrap()["value"], 1);

    let manifest = home
        .path()
        .join("workspace/workers")
        .join(&outcome.worker.worker_id)
        .join("versions")
        .join(&outcome.version)
        .join("manifest.json");
    let mut bytes = std::fs::read(&manifest).unwrap();
    bytes.push(b'\n');
    std::fs::write(&manifest, bytes).unwrap();

    let second = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"value":2}),
            "resident-snapshot-second",
        ))
        .await
        .unwrap();
    assert_eq!(second.output.unwrap()["value"], 2);
    runtime.supervise_residents().await;
    assert!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        "supervision must use metadata pinned to the verified live process"
    );

    runtime
        .stop_residents(Some(&outcome.worker.worker_id))
        .await;
    let after_restart = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"value":3}),
            "resident-snapshot-after-restart",
        ))
        .await
        .unwrap();
    assert_eq!(after_restart.status, "failed");
    assert!(
        after_restart
            .error
            .as_deref()
            .is_some_and(|error| error.contains("integrity check failed"))
    );
}

#[tokio::test]
async fn native_client_action_service_allows_model_cold_start_during_activation() {
    let (runtime, _home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let script = r#"import http.server,json,sys,time
time.sleep(5.25)
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{\"text\":\"ready\"}')
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("resident-native-action".to_owned());
    bundle.name = "Resident Native Action".to_owned();
    bundle.description = "Resident service backing a latency-sensitive native action".to_owned();
    bundle.tool_name = Some("worker_resident_native_action".to_owned());
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["audioBase64","mimeType","fileName"],
        "properties":{
            "audioBase64":{"type":"string","minLength":1},
            "mimeType":{"type":"string","minLength":1},
            "fileName":{"type":"string","minLength":1}
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["text"],
        "properties":{"text":{"type":"string"}}
    });
    bundle.client_actions = vec![WorkerClientAction::SpeechTranscription];
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script.to_owned(),
            port.to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };

    let outcome = runtime.upsert(bundle, None).await.unwrap();

    assert_eq!(runtime.residents.len(), 1);
    assert!(
        runtime
            .running_resident_worker(&outcome.worker.worker_id, &outcome.version)
            .await
            .is_some()
    );
}

#[tokio::test]
async fn cancelling_one_resident_invocation_keeps_the_service_available() {
    let (runtime, _home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let script = r#"import http.server,json,sys,time
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); value=json.loads(self.rfile.read(n))
  if value.get('slow'): time.sleep(30)
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(value).encode())
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("precise-resident-cancel".to_owned());
    bundle.name = "Precise Resident Cancel".to_owned();
    bundle.description = "Resident fixture proving invocation-scoped cancellation".to_owned();
    bundle.tool_name = Some("worker_precise_resident_cancel".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script.to_owned(),
            port.to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id.clone();
    let invoke_runtime = Arc::clone(&runtime);
    let invoke_worker_id = worker_id.clone();
    let invocation = tokio::spawn(async move {
        invoke_runtime
            .invoke(request(
                &invoke_worker_id,
                json!({"slow":true}),
                "precise-resident-cancel",
            ))
            .await
            .unwrap()
    });

    let run = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(run) = runtime
                .store()
                .runs_filtered(Some(&worker_id), Some("running"), 1)
                .unwrap()
                .into_iter()
                .next()
            {
                break run;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("resident invocation did not enter running state");
    let cancelled = runtime.cancel_invocation(&run.invocation_id).await.unwrap();
    assert_eq!(cancelled.status, "cancelled");
    assert_eq!(invocation.await.unwrap().status, "cancelled");
    assert_eq!(runtime.residents.len(), 1);
    assert!(
        runtime
            .store()
            .summary(&worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );

    let next = runtime
        .invoke(request(
            &worker_id,
            json!({"slow":false,"value":"still-running"}),
            "resident-after-cancel",
        ))
        .await
        .unwrap();
    assert_eq!(next.status, "completed", "{next:?}");
    assert_eq!(next.output.unwrap()["value"], "still-running");
}

#[tokio::test]
async fn oversized_resident_response_fails_bounded_and_disables_the_worker() {
    let (runtime, _home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let script = format!(
        r#"import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{{}}')
 def do_POST(self):
  self.send_response(200); self.end_headers(); self.wfile.write(b'x'*{})
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#,
        MAX_PROCESS_CAPTURE_BYTES + 1
    );
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("oversized-resident".to_owned());
    bundle.name = "Oversized Resident".to_owned();
    bundle.description = "Resident response ceiling regression fixture".to_owned();
    bundle.tool_name = Some("worker_oversized_resident".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script,
            port.to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let record = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "oversized-resident",
        ))
        .await
        .unwrap();

    assert_eq!(record.status, "failed", "{record:?}");
    assert!(
        record
            .error
            .as_deref()
            .is_some_and(|error| error.contains("4194304-byte ceiling")),
        "{record:?}"
    );
    assert_eq!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        false
    );
    assert!(runtime.residents.is_empty());
}

#[tokio::test]
async fn resident_supervisor_disables_an_exited_service_without_another_invocation() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("resident-supervision".to_owned());
    bundle.name = "Resident Supervision".to_owned();
    bundle.description =
        "Long-lived resident fixture whose unexpected exit must be detected proactively".to_owned();
    bundle.tool_name = Some("worker_resident_supervision".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 30".to_owned()],
        invoke_url: "http://127.0.0.1:1/invoke".to_owned(),
        health_url: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();
    let WorkerRunner::Service {
        command,
        health_url,
        ..
    } = &active.bundle.runner
    else {
        panic!("fixture must be a resident service");
    };
    runtime
        .ensure_resident(&active, command, health_url.as_deref(), &HashMap::new())
        .await
        .unwrap();
    let key = resident_key(&active);
    let process = runtime
        .residents
        .get(&key)
        .expect("resident process")
        .clone();
    process
        .lock()
        .await
        .child
        .as_mut()
        .expect("resident child")
        .terminate()
        .await;

    runtime.supervise_residents().await;

    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!summary.enabled);
    assert_eq!(summary.health, "failed");
    assert!(runtime.residents.is_empty());
    assert!(
        runtime
            .host
            .inspect_function(
                &FunctionId::new("worker_kernel::dynamic_resident-supervision").unwrap(),
                &system_actor(),
            )
            .await
            .is_err(),
        "failed resident must be removed from direct routing"
    );
    let inbox = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert!(inbox.iter().any(|item| {
        item["result"]["phase"] == "resident_supervision" && item["result"]["disabled"] == true
    }));
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    assert_eq!(
        inspection["healthHistory"][0]["source"],
        "resident_supervision"
    );
}

#[tokio::test]
async fn resident_supervisor_requires_repeated_health_failures_before_disabling() {
    let (runtime, _home) = test_runtime(None);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let script = r#"import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(503); self.end_headers()
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("resident-health-supervision".to_owned());
    bundle.name = "Resident Health Supervision".to_owned();
    bundle.description =
        "Resident fixture requiring repeated health failures before disablement".to_owned();
    bundle.tool_name = Some("worker_resident_health_supervision".to_owned());
    bundle.runner = WorkerRunner::Service {
        command: vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "-c".to_owned(),
            script.to_owned(),
            port.to_string(),
        ],
        invoke_url: format!("http://127.0.0.1:{port}/invoke"),
        health_url: Some(format!("http://127.0.0.1:{port}/health")),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();
    let WorkerRunner::Service { command, .. } = &active.bundle.runner else {
        panic!("fixture must be a resident service");
    };
    runtime
        .ensure_resident(&active, command, None, &HashMap::new())
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    for attempt in 1..RESIDENT_HEALTH_FAILURE_LIMIT {
        runtime.supervise_residents().await;
        assert!(
            runtime
                .store()
                .summary(&outcome.worker.worker_id)
                .unwrap()
                .unwrap()
                .enabled,
            "transient resident health failure {attempt} disabled the worker"
        );
    }
    runtime.supervise_residents().await;

    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!summary.enabled);
    assert_eq!(summary.health, "failed");
}
