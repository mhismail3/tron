//! Integration tests for the isolated JavaScript program worker process.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

fn worker_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tron-program-worker"))
}

fn spawn_worker() -> std::process::Child {
    Command::new(worker_bin())
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn worker")
}

fn read_json(reader: &mut BufReader<std::process::ChildStdout>) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).expect("read worker line");
    assert!(!line.is_empty(), "worker closed stdout");
    serde_json::from_str(line.trim_end()).expect("worker json")
}

fn write_json(writer: &mut std::process::ChildStdin, value: Value) {
    writeln!(writer, "{value}").expect("write worker stdin");
    writer.flush().expect("flush worker stdin");
}

#[test]
fn program_worker_runs_javascript_without_host_access() {
    let mut child = spawn_worker();
    let mut writer = child.stdin.take().expect("stdin");
    let mut reader = BufReader::new(child.stdout.take().expect("stdout"));
    assert_eq!(
        read_json(&mut reader),
        json!({"type": "ready", "protocol_version": 1})
    );
    write_json(
        &mut writer,
        json!({
            "type": "run",
            "request": {
                "language": "javascript",
                "code": "return { fetch: typeof fetch, process: typeof process, value: args.value };",
                "args": {"value": 42},
                "timeoutMs": 500,
                "budget": {"memoryBytes": 8388608, "maxOutputBytes": 16384, "maxLogBytes": 16384},
                "idempotencyKey": "test-program-worker"
            }
        }),
    );
    let result = read_json(&mut reader);
    assert_eq!(result["type"], "result");
    assert_eq!(result["result"]["status"], "ok");
    assert_eq!(
        result["result"]["output"],
        json!({"fetch": "undefined", "process": "undefined", "value": 42})
    );
    assert!(child.wait().expect("wait").success());
}

#[test]
fn program_worker_round_trips_host_calls() {
    let mut child = spawn_worker();
    let mut writer = child.stdin.take().expect("stdin");
    let mut reader = BufReader::new(child.stdout.take().expect("stdout"));
    assert_eq!(
        read_json(&mut reader),
        json!({"type": "ready", "protocol_version": 1})
    );
    write_json(
        &mut writer,
        json!({
            "type": "run",
            "request": {
                "language": "javascript",
                "code": "const result = tools.execute({ intent: 'read README', target: 'filesystem::read_file', arguments: { path: 'README.md' } }); return result;",
                "args": {},
                "timeoutMs": 500,
                "budget": {"memoryBytes": 8388608, "maxOutputBytes": 16384, "maxLogBytes": 16384},
                "idempotencyKey": "test-program-worker-host"
            }
        }),
    );
    let call = read_json(&mut reader);
    assert_eq!(call["type"], "host_call");
    assert!(call.get("primitive").is_none());
    assert_eq!(call["payload"]["target"], "filesystem::read_file");
    let id = call["id"].as_str().expect("host call id").to_owned();
    write_json(
        &mut writer,
        json!({
            "type": "host_result",
            "id": id,
            "value": {
                "ok": true,
                "details": {
                    "childInvocations": ["child-search-1"],
                    "selectedImplementation": "first_party.capability.v1.search"
                }
            }
        }),
    );
    let result = read_json(&mut reader);
    assert_eq!(result["type"], "result");
    assert_eq!(result["result"]["status"], "ok");
    assert_eq!(result["result"]["output"]["ok"], true);
    assert_eq!(
        result["result"]["childInvocations"],
        json!(["child-search-1"])
    );
    assert!(child.wait().expect("wait").success());
}
