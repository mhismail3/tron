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
        .inbox(Some(&outcome.worker.worker_id), 10)
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
