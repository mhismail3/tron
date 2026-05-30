use super::*;
use rusqlite::Connection;
use serde_json::json;
use tempfile::tempdir;

fn request_for_session(session_id: &str, key: &str, payload: Value) -> EngineApprovalRequest {
    EngineApprovalRequest {
        function_id: FunctionId::new("danger::write").unwrap(),
        payload,
        causal_context: CausalContext::new(
            ActorId::new("agent").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant").unwrap(),
            TraceId::generate(),
        )
        .with_scope("danger.write")
        .with_session_id(session_id)
        .with_workspace_id("workspace-a")
        .with_idempotency_key(key),
        delivery_mode: DeliveryMode::Sync,
    }
}

#[test]
fn sqlite_approval_idempotency_is_scoped_after_global_migration() {
    let temp = tempdir().unwrap();
    let path = temp.path().join("approvals.sqlite");
    Connection::open(&path)
        .unwrap()
        .execute_batch(
            r#"
CREATE TABLE engine_approvals (
  approval_id TEXT PRIMARY KEY,
  function_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_fingerprint TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  authority_grant_id TEXT NOT NULL,
  authority_scopes_json TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  parent_invocation_id TEXT,
  trigger_id TEXT,
  session_id TEXT,
  workspace_id TEXT,
  idempotency_key TEXT UNIQUE,
  delivery_mode TEXT NOT NULL,
  status TEXT NOT NULL,
  decision_actor_id TEXT,
  decided_at TEXT,
  result_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
"#,
        )
        .unwrap();

    let mut store = SqliteEngineApprovalStore::open(&path).unwrap();
    let first = store
        .request(request_for_session(
            "session-a",
            "shared-approval-key",
            json!({"value": 1}),
        ))
        .unwrap();
    let second = store
        .request(request_for_session(
            "session-b",
            "shared-approval-key",
            json!({"value": 2}),
        ))
        .unwrap();

    assert_ne!(first.record.approval_id, second.record.approval_id);
    assert_eq!(first.record.idempotency_key, second.record.idempotency_key);
    let table_sql: String = store
        .conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'engine_approvals'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!table_sql.contains("idempotency_key TEXT UNIQUE"));
}

#[test]
fn sqlite_approval_idempotency_still_conflicts_within_scope() {
    let temp = tempdir().unwrap();
    let path = temp.path().join("approvals.sqlite");
    let mut store = SqliteEngineApprovalStore::open(&path).unwrap();
    store
        .request(request_for_session(
            "session-a",
            "session-conflict",
            json!({"value": 1}),
        ))
        .unwrap();
    let result = store.request(request_for_session(
        "session-a",
        "session-conflict",
        json!({"value": 2}),
    ));

    assert!(matches!(
        result,
        Err(EngineError::IdempotencyConflict { key, .. }) if key == "session-conflict"
    ));
}
