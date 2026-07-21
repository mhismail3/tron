use super::*;

use crate::domains::worker_kernel::types::{BUNDLE_SCHEMA, SourceProvenance, WorkerRunner};
use crate::shared::storage::StorePayloadOptions;

fn complete_bundle() -> WorkerBundle {
    let mut bundle = WorkerBundle {
        schema_version: BUNDLE_SCHEMA.to_owned(),
        worker_id: Some("importable-worker".to_owned()),
        name: "Importable Worker".to_owned(),
        description: "A complete executable legacy worker bundle".to_owned(),
        tool_name: Some("worker_importable".to_owned()),
        input_schema: json!({"type":"object"}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Command {
            command: vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()],
        },
        files: Default::default(),
        dependencies: Vec::new(),
        triggers: vec![WorkerTrigger::Manual {
            id: "manual".to_owned(),
        }],
        secret_bindings: Vec::new(),
        smoke_tests: Vec::new(),
        health_checks: Vec::new(),
        provenance: vec![SourceProvenance {
            source: "legacy:test".to_owned(),
            revision: Some("1".to_owned()),
            checksum: None,
        }],
        routing: Default::default(),
    };
    let _ = bundle.files.insert(
        "worker.sh".to_owned(),
        "# deterministic fixture\n".repeat(700),
    );
    bundle
}

fn legacy_fixture(home: &Path) -> PathBuf {
    fs::create_dir_all(home.join("profiles/user")).unwrap();
    fs::write(home.join("profiles/user/profile.toml"), "[settings]\n").unwrap();
    let database = home.join("internal/database/tron.sqlite");
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    crate::shared::storage::ensure_storage_schema(&connection).unwrap();
    connection.execute_batch(LEGACY_SCHEMA).unwrap();

    let bundle_payload = crate::shared::storage::store_json_value(
        &connection,
        &json!({"workerBundle": complete_bundle()}),
        &StorePayloadOptions::new(
            "engine_resource_version",
            "v-worker",
            "payload_json",
            "legacy",
        ),
    )
    .unwrap();
    connection
        .execute(
            "INSERT INTO engine_resource_versions VALUES('v-worker','hash-worker',?1)",
            [&bundle_payload],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO engine_resources VALUES('worker-package-complete','worker_package','candidate','v-worker')",
            [],
        )
        .unwrap();
    let inert = json!({
        "proposalId":"last30days",
        "sourceUrl":"https://example.invalid/last30days-skill",
        "summary":"metadata without an executable runner or schemas"
    })
    .to_string();
    connection
        .execute(
            "INSERT INTO engine_resource_versions VALUES('v-last30days','hash-last30days',?1)",
            [&inert],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO engine_resources VALUES('module-proposal-last30days','module_proposal','draft','v-last30days')",
            [],
        )
        .unwrap();

    let shared = json!({"evidence":"shared".repeat(5000)});
    let retained_result = store_fixture_payload(
        &connection,
        &shared,
        "engine_invocation",
        "invocation-one",
        "result_json",
    );
    let compensation_result = store_fixture_payload(
        &connection,
        &shared,
        "engine_compensation",
        "compensation-shared",
        "result_json",
    );
    let exclusive_compensation = store_fixture_payload(
        &connection,
        &json!({"exclusive":"compensation".repeat(5000)}),
        "engine_compensation",
        "compensation-exclusive",
        "error_json",
    );
    connection
        .execute(
            "INSERT INTO engine_invocations VALUES(
                'invocation-one','legacy::write','legacy-worker',1,1,'agent-one','\"Agent\"',
                'grant-one','[\"legacy.write\"]','trace-one',NULL,NULL,'session-one','workspace-one',
                '\"Sync\"','session','session-one','[\"lease-one\"]','pending','[\"resource-one\"]',
                'key-one',NULL,1,?1,NULL,'2026-01-01T00:00:00Z'
             )",
            [&retained_result],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO engine_compensation_records VALUES('compensation-shared',?1)",
            [&compensation_result],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO engine_compensation_records VALUES('compensation-exclusive',?1)",
            [&exclusive_compensation],
        )
        .unwrap();
    drop(connection);
    database
}

fn store_fixture_payload(
    connection: &Connection,
    value: &Value,
    owner_kind: &str,
    owner_id: &str,
    field: &str,
) -> String {
    crate::shared::storage::store_json_value(
        connection,
        value,
        &StorePayloadOptions::new(owner_kind, owner_id, field, "audit"),
    )
    .unwrap()
}

fn table_present(connection: &Connection, table: &str) -> bool {
    table_exists(connection, table).unwrap()
}

#[test]
fn retirement_is_snapshot_first_transactional_idempotent_and_restore_safe() {
    let home = tempfile::tempdir().unwrap();
    let database = legacy_fixture(home.path());
    let root = home.path().join("workspace/workers");

    let failure = prepare_worker_first_retirement_with_fault(home.path(), "user", &database, true)
        .unwrap_err();
    assert!(failure.contains("injected"));
    let connection = Connection::open(&database).unwrap();
    assert!(table_present(&connection, "engine_resources"));
    assert!(read_retirement_marker(&connection).unwrap().is_none());
    assert_eq!(
        scalar_text(
            &connection,
            "SELECT replay_behavior_json FROM engine_idempotency_entries"
        ),
        "\"Compensate\""
    );
    drop(connection);

    prepare_worker_first_retirement(home.path(), "user", &database).unwrap();
    assert_migrated_state(&database, &root);
    let snapshots = super::super::snapshot::list_snapshots(home.path()).unwrap();
    assert_eq!(snapshots.len(), 1);

    prepare_worker_first_retirement(home.path(), "user", &database).unwrap();
    assert_eq!(
        super::super::snapshot::list_snapshots(home.path())
            .unwrap()
            .len(),
        1
    );

    super::super::snapshot::restore_snapshot(&snapshots[0], home.path()).unwrap();
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join(IMPORT_REPORT_FILE), b"{\"format\":\"stale\"}").unwrap();
    prepare_worker_first_retirement(home.path(), "user", &database).unwrap();
    assert_migrated_state(&database, &root);
}

fn assert_migrated_state(database: &Path, root: &Path) {
    let report: Value =
        serde_json::from_slice(&fs::read(root.join(IMPORT_REPORT_FILE)).unwrap()).unwrap();
    assert_eq!(report["format"], IMPORT_FORMAT);
    assert_eq!(report["schemaVersion"], 5);
    assert_eq!(report["sourceCounts"]["resources"], 2);
    assert_eq!(report["sourceCounts"]["invocations"], 1);
    assert_eq!(report["catalogChangesRetired"], 2);
    assert_eq!(report["streamSubscriptionsRetired"], 2);
    assert_eq!(report["importedCandidates"].as_array().unwrap().len(), 1);
    assert_eq!(report["unconvertibleRecords"].as_array().unwrap().len(), 1);
    assert_eq!(
        report["unconvertibleRecords"][0]["resourceId"],
        "module-proposal-last30days"
    );
    let imported_path = PathBuf::from(report["importedCandidates"][0]["path"].as_str().unwrap());
    assert!(imported_path.join("manifest.json").is_file());
    let candidate: Value =
        serde_json::from_slice(&fs::read(imported_path.join("candidate.json")).unwrap()).unwrap();
    assert_eq!(candidate["status"], "inactive_candidate");
    assert!(!root.join("importable-worker/worker.json").exists());

    let connection = Connection::open(database).unwrap();
    for table in RETIRED_TABLES {
        assert!(
            !table_present(&connection, table),
            "retired table remains: {table}"
        );
    }
    verify_retired_schema(&connection).unwrap();
    verify_payload_ownership(&connection).unwrap();
    assert!(read_retirement_marker(&connection).unwrap().is_some());
    assert_eq!(
        scalar_text(&connection, "SELECT value FROM retained_sessions"),
        "retained-session"
    );
    assert_eq!(
        scalar_text(&connection, "SELECT value FROM engine_state_entries"),
        "retained-state"
    );
    assert_eq!(
        scalar_text(&connection, "SELECT value FROM engine_stream_events"),
        "retained-stream"
    );
    assert_eq!(
        scalar_text(
            &connection,
            "SELECT replay_behavior_json FROM engine_idempotency_entries"
        ),
        "\"Reject\""
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM engine_catalog_changes", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
    assert_eq!(
        scalar_text(&connection, "SELECT kind_json FROM engine_catalog_changes"),
        "\"FunctionRegistered\""
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM engine_stream_subscriptions WHERE active=0",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        2
    );
    assert_eq!(
        scalar_text(
            &connection,
            "SELECT subscription_id FROM engine_stream_subscriptions WHERE active=1"
        ),
        "caller-durable-subscription"
    );
    drop(connection);
    let ledger =
        crate::engine::durability::ledger::SqliteEngineLedgerStore::open(database).unwrap();
    assert!(
        crate::engine::EngineLedgerStore::list_catalog_changes(&ledger)
            .unwrap()
            .iter()
            .all(|change| matches!(
                change.subject_kind,
                crate::engine::CatalogSubjectKind::Worker
                    | crate::engine::CatalogSubjectKind::Function
            ))
    );
    drop(ledger);
    let connection = Connection::open(database).unwrap();
    let shared_blob_count: i64 = connection
        .query_row(
            "SELECT b.ref_count FROM blobs b JOIN storage_payload_refs r ON r.payload_blob_id=b.id
             WHERE r.owner_kind='engine_invocation' AND r.owner_id='invocation-one'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(shared_blob_count, 1);
}

fn scalar_text(connection: &Connection, query: &str) -> String {
    connection.query_row(query, [], |row| row.get(0)).unwrap()
}

const LEGACY_SCHEMA: &str = r#"
CREATE TABLE engine_resource_type_definitions(kind TEXT PRIMARY KEY);
CREATE TABLE engine_resources(resource_id TEXT PRIMARY KEY,kind TEXT NOT NULL,lifecycle TEXT NOT NULL,current_version_id TEXT NOT NULL);
CREATE TABLE engine_resource_versions(version_id TEXT PRIMARY KEY,content_hash TEXT NOT NULL,payload_json TEXT NOT NULL);
CREATE TABLE engine_resource_links(link_id TEXT PRIMARY KEY);
CREATE TABLE engine_resource_events(event_id TEXT PRIMARY KEY);
CREATE TABLE engine_grants(grant_id TEXT PRIMARY KEY);
CREATE TABLE engine_grant_events(event_id TEXT PRIMARY KEY);
CREATE TABLE engine_resource_leases(lease_id TEXT PRIMARY KEY);
CREATE TABLE engine_compensation_records(compensation_id TEXT PRIMARY KEY,result_json TEXT);
CREATE TABLE engine_catalog_workers(worker_id TEXT PRIMARY KEY);
CREATE TABLE engine_catalog_functions(function_id TEXT PRIMARY KEY);
CREATE TABLE engine_catalog_changes(
 id TEXT PRIMARY KEY,before_revision INTEGER NOT NULL,after_revision INTEGER NOT NULL,
 kind_json TEXT NOT NULL,subject_id TEXT NOT NULL,subject_kind_json TEXT NOT NULL,
 class_json TEXT NOT NULL,visibility_json TEXT NOT NULL,session_id TEXT,workspace_id TEXT,
 owner_worker_id TEXT,timestamp TEXT NOT NULL);
CREATE TABLE engine_queue_items(queue_id TEXT PRIMARY KEY);
CREATE TABLE engine_invocations(
 invocation_id TEXT PRIMARY KEY,function_id TEXT NOT NULL,worker_id TEXT NOT NULL,function_revision INTEGER NOT NULL,
 catalog_revision INTEGER NOT NULL,actor_id TEXT NOT NULL,actor_kind_json TEXT NOT NULL,authority_grant_id TEXT NOT NULL,
 authority_scopes_json TEXT NOT NULL,trace_id TEXT NOT NULL,parent_invocation_id TEXT,trigger_id TEXT,session_id TEXT,
 workspace_id TEXT,delivery_mode_json TEXT NOT NULL,idempotency_scope_kind TEXT,idempotency_scope_value TEXT,
 resource_lease_ids_json TEXT NOT NULL DEFAULT '[]',compensation_status TEXT,produced_resource_refs_json TEXT NOT NULL DEFAULT '[]',
 idempotency_key TEXT,replayed_from TEXT,succeeded INTEGER NOT NULL,result_json TEXT,error_json TEXT,timestamp TEXT NOT NULL);
CREATE INDEX idx_engine_invocations_trace ON engine_invocations(trace_id);
CREATE TABLE engine_idempotency_entries(
 function_id TEXT NOT NULL,scope_kind TEXT NOT NULL,scope_value TEXT NOT NULL,idempotency_key TEXT NOT NULL,
 payload_fingerprint TEXT NOT NULL,function_revision INTEGER NOT NULL,replay_behavior_json TEXT NOT NULL,status_json TEXT NOT NULL,
 first_invocation_id TEXT NOT NULL,latest_invocation_id TEXT NOT NULL,outcome_value_json TEXT,outcome_error_json TEXT,
 created_at TEXT NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(function_id,scope_kind,scope_value,idempotency_key));
CREATE TABLE retained_sessions(id TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE engine_state_entries(id TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE engine_stream_events(id TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE engine_stream_subscriptions(
 subscription_id TEXT PRIMARY KEY,topic TEXT NOT NULL,cursor INTEGER NOT NULL,
 visibility TEXT NOT NULL,session_id TEXT,workspace_id TEXT,active INTEGER NOT NULL,
 created_at TEXT NOT NULL);
INSERT INTO engine_resource_type_definitions VALUES('worker_package');
INSERT INTO engine_resource_type_definitions VALUES('module_proposal');
INSERT INTO engine_resource_links VALUES('link-one');
INSERT INTO engine_resource_events VALUES('event-one');
INSERT INTO engine_grants VALUES('grant-one');
INSERT INTO engine_grant_events VALUES('grant-event-one');
INSERT INTO engine_resource_leases VALUES('lease-one');
INSERT INTO engine_catalog_workers VALUES('legacy-worker');
INSERT INTO engine_catalog_functions VALUES('legacy::function');
INSERT INTO engine_catalog_changes VALUES(
 'change-function',0,1,'"FunctionRegistered"','engine::state_get','"Function"',
 '"Availability"','"System"',NULL,NULL,'engine','2026-01-01T00:00:00Z');
INSERT INTO engine_catalog_changes VALUES(
 'change-trigger',1,2,'"TriggerRegistered"','legacy-trigger','"Trigger"',
 '"Availability"','"Internal"',NULL,NULL,NULL,'2026-01-01T00:00:01Z');
INSERT INTO engine_catalog_changes VALUES(
 'change-trigger-type',2,3,'"TriggerTypeRegistered"','legacy-trigger-type','"TriggerType"',
 '"Availability"','"Internal"',NULL,NULL,NULL,'2026-01-01T00:00:02Z');
INSERT INTO engine_queue_items VALUES('queue-one');
INSERT INTO retained_sessions VALUES('session-one','retained-session');
INSERT INTO engine_state_entries VALUES('state-one','retained-state');
INSERT INTO engine_stream_events VALUES('stream-one','retained-stream');
INSERT INTO engine_stream_subscriptions VALUES(
 'engine-ws:019f83d7-a536-7c00-8000-000000000001:019f83d7-a536-7c00-8000-000000000002',
 'events.session',10,'system',NULL,NULL,1,'2026-01-01T00:00:00Z');
INSERT INTO engine_stream_subscriptions VALUES(
 'engine-ws-stateless:019f83d7-a536-7c00-8000-000000000003:019f83d7-a536-7c00-8000-000000000004',
 'events.session',11,'system',NULL,NULL,1,'2026-01-01T00:00:00Z');
INSERT INTO engine_stream_subscriptions VALUES(
 'caller-durable-subscription','events.session',12,'system',NULL,NULL,1,
 '2026-01-01T00:00:00Z');
INSERT INTO engine_idempotency_entries VALUES('legacy::write','session','session-one','key-one','fingerprint',1,'"Compensate"','"Completed"','invocation-one','invocation-one',NULL,NULL,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
"#;
