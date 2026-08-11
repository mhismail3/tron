use std::fs;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};
use tempfile::tempdir;

use super::*;
use crate::domains::code_runtime::evaluator::BrokerRequest;
use crate::domains::code_runtime::store::CodeRuntimeStore;

#[test]
fn oxc_strips_types_and_rejects_module_authority() {
    let compiled =
        compile_typescript("const answer: number = 42; answer", SourceKind::Cell).expect("compile");
    assert!(!compiled.javascript.contains(": number"));
    assert!(compiled.javascript.contains("answer"));

    let error = compile_typescript("import x from './x'; x", SourceKind::Cell)
        .expect_err("imports must be unavailable");
    assert!(error.to_string().contains("module loading"));
    let error = compile_typescript("enum Direction { Up }", SourceKind::Cell)
        .expect_err("runtime TS constructs must be unavailable");
    assert!(error.to_string().contains("enums/namespaces"));
}

#[test]
fn lexical_bindings_and_top_level_await_rehydrate_after_restart() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let service = CodeRuntimeService::open(&database).expect("service");
    let first = service
        .run_in_process_for_test(request(
            "one",
            "const base: number = await Promise.resolve(40); base",
        ))
        .expect("first");
    assert_eq!(first.status, CellStatus::Committed, "{first:?}");
    assert_eq!(first.value, Some(json!(40)));
    let second = service
        .run_in_process_for_test(request("two", "base + 2"))
        .expect("second");
    assert_eq!(second.value, Some(json!(42)));
    drop(service);

    let reopened = CodeRuntimeService::open(&database).expect("reopen");
    let third = reopened
        .run_in_process_for_test(request("three", "base + 3"))
        .expect("third");
    assert_eq!(third.value, Some(json!(43)));
    let inspect = reopened.inspect("agent-1").expect("inspect");
    assert_eq!(inspect.committed_cells, 3);
    assert!(inspect.journal_bytes > 0);
}

#[test]
fn failed_cell_is_audited_but_excluded_from_future_replay() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let service = CodeRuntimeService::open(database).expect("service");
    let failed = service
        .run_in_process_for_test(request(
            "bad",
            "const poisoned = 7; throw new Error('stop')",
        ))
        .expect("durable failure");
    assert_eq!(failed.status, CellStatus::Failed);
    let next = service
        .run_in_process_for_test(request("good", "typeof poisoned"))
        .expect("next");
    assert_eq!(next.status, CellStatus::Committed);
    assert_eq!(next.value, Some(json!("undefined")));
    assert_eq!(service.inspect("agent-1").unwrap().committed_cells, 1);
}

#[derive(Default)]
struct CountingBroker {
    calls: AtomicUsize,
}

impl Broker for CountingBroker {
    fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(request.input.clone())
    }
}

#[test]
fn broker_effects_and_invocations_replay_without_reexecution() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let broker = Arc::new(CountingBroker::default());
    let service = CodeRuntimeService::with_test_broker_and_limits(
        &database,
        broker.clone(),
        RuntimeLimits::default(),
    )
    .expect("service");
    let first = service
        .run_in_process_for_test(request(
            "effect",
            "const remembered = tron.call('test.echo.v1', { value: 9 }); remembered.value",
        ))
        .expect("effect");
    assert_eq!(first.value, Some(json!(9)));
    assert_eq!(broker.calls.load(Ordering::SeqCst), 1);

    let duplicate = service
        .run_in_process_for_test(request(
            "effect",
            "const remembered = tron.call('test.echo.v1', { value: 9 }); remembered.value",
        ))
        .expect("duplicate");
    assert!(duplicate.replayed);
    assert_eq!(broker.calls.load(Ordering::SeqCst), 1);

    service
        .run_in_process_for_test(request("after", "remembered.value + 1"))
        .expect("rehydrate");
    assert_eq!(broker.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn interrupted_admission_resumes_same_cell_and_invocation_conflicts_are_rejected() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let store = CodeRuntimeStore::open(&database).expect("store");
    let source = "const resumed: number = 5; resumed";
    let compiled = compile_typescript(source, SourceKind::Cell).expect("compile");
    let (_, admitted, _) = store
        .admit_cell(
            "agent-1",
            "recover",
            Some("assignment-1"),
            source,
            &compiled.source_digest,
            &compiled.javascript,
            &compiled.compiled_digest,
            &RuntimeLimits::default(),
        )
        .expect("admit");
    drop(store);

    let service = CodeRuntimeService::open(&database).expect("service");
    let recovered = service
        .run_in_process_for_test(request("recover", source))
        .expect("resume");
    assert_eq!(recovered.cell_id, admitted.cell_id);
    assert_eq!(recovered.status, CellStatus::Committed);
    assert_eq!(recovered.value, Some(json!(5)));
    let conflict = service.run_in_process_for_test(request("recover", "6"));
    assert!(conflict.is_err());
}

#[test]
fn cancellation_and_wall_clock_limits_terminalize_without_committing() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let mut limits = RuntimeLimits::default();
    limits.wall_time_ms = 20;
    let service =
        CodeRuntimeService::with_test_broker_and_limits(database, Arc::new(NoopBroker), limits)
            .expect("service");
    let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let cancelled_result = service
        .run_in_process_with_cancellation_for_test(request("cancel", "1 + 1"), cancelled)
        .expect("cancelled result");
    assert_eq!(cancelled_result.status, CellStatus::Cancelled);
    let timed_out = service
        .run_in_process_for_test(request("timeout", "while (true) {}"))
        .expect("timeout result");
    assert_eq!(timed_out.status, CellStatus::TimedOut);
    assert_eq!(service.inspect("agent-1").unwrap().committed_cells, 0);
}

#[test]
fn quickjs_has_no_ambient_host_authority_and_sdk_is_frozen() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let service = CodeRuntimeService::open(database).expect("service");
    let result = service
        .run_in_process_for_test(request(
            "ambient",
            "({ process: typeof process, require: typeof require, fetch: typeof fetch, Deno: typeof Deno, eval: typeof eval, replayPrivate: Function('return typeof __tronCandidate')(), frozen: Object.isFrozen(tron), hasBash: 'bash' in tron })",
        ))
        .expect("run");
    assert_eq!(
        result.value,
        Some(json!({
            "process": "undefined",
            "require": "undefined",
            "fetch": "undefined",
            "Deno": "undefined",
            "eval": "undefined",
            "replayPrivate": "undefined",
            "frozen": true,
            "hasBash": false
        }))
    );
}

#[test]
fn manual_reset_changes_epoch_without_erasing_audit_history() {
    let directory = tempdir().expect("tempdir");
    let database = directory.path().join("tron.sqlite");
    initialize_code_database(&database);
    let service = CodeRuntimeService::open(database).expect("service");
    service
        .run_in_process_for_test(request("one", "const x = 1; x"))
        .unwrap();
    let reset = service.reset("agent-1").expect("reset");
    assert_eq!(reset.epoch, 1);
    let result = service
        .run_in_process_for_test(request("two", "typeof x"))
        .unwrap();
    assert_eq!(result.value, Some(json!("undefined")));
}

#[test]
fn skills_start_empty_then_shadow_and_pin_callable_modules() {
    let directory = tempdir().expect("tempdir");
    let profile = directory.path().join("profile-skills");
    let project = directory.path().join("project-skills");
    let empty = SkillCatalog::new(&profile, Some(project.clone()), false);
    assert!(empty.discover().expect("empty").is_empty());

    write_skill(
        &profile,
        "index",
        "Profile Index",
        "return input",
        "profile",
    );
    write_skill(
        &project,
        "index",
        "Project Index",
        "return input",
        "project",
    );
    let untrusted = SkillCatalog::new(&profile, Some(project.clone()), false);
    assert_eq!(untrusted.discover().unwrap()[0].name, "Profile Index");
    let trusted = SkillCatalog::new(&profile, Some(project), true);
    assert_eq!(trusted.discover().unwrap()[0].name, "Project Index");
    let module = trusted.resolve_module("index", "scripts/main.ts").unwrap();
    assert_eq!(module.source_digest.len(), 64);
    assert_eq!(module.compiled_digest.len(), 64);
    assert!(module.javascript.contains("export default"));
}

#[test]
fn skill_discovery_pages_summaries_and_inspects_one_instruction_body() {
    let directory = tempdir().expect("tempdir");
    let profile = directory.path().join("skills");
    for index in 0..70 {
        write_skill(
            &profile,
            &format!("skill-{index:03}"),
            &format!("Skill {index:03}"),
            &"instruction ".repeat(1_000),
            "paged",
        );
    }
    let catalog = SkillCatalog::new(&profile, None, false);
    let first = catalog
        .discover_page(None, None, Some(32))
        .expect("first page");
    assert_eq!(first.skills.len(), 32);
    let first_json = serde_json::to_vec(&first).unwrap();
    assert!(first_json.len() < 64 * 1024);
    assert!(!String::from_utf8_lossy(&first_json).contains("instruction"));
    let second = catalog
        .discover_page(None, first.next_cursor.as_deref(), Some(32))
        .expect("second page");
    assert_eq!(second.skills.len(), 32);
    assert!(
        first
            .skills
            .iter()
            .all(|row| !second.skills.iter().any(|next| next.id == row.id))
    );
    let inspected = catalog.inspect("skill-000").expect("inspect");
    assert!(inspected.instructions.len() > 10_000);
}

#[derive(Default)]
struct RecordingBroker {
    requests: Mutex<Vec<BrokerRequest>>,
}

impl Broker for RecordingBroker {
    fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.requests.lock().unwrap().push(request.clone());
        Ok(request.input.clone())
    }
}

#[test]
fn skill_state_handle_forces_an_engine_derived_cross_skill_namespace() {
    let directory = tempdir().expect("tempdir");
    let root = directory.path().join("skills");
    write_state_skill(&root, "alpha");
    write_state_skill(&root, "beta");
    let catalog = SkillCatalog::new(&root, None, false);
    let alpha = catalog.resolve_module("alpha", "scripts/main.ts").unwrap();
    let beta = catalog.resolve_module("beta", "scripts/main.ts").unwrap();
    let broker = Arc::new(RecordingBroker::default());
    let attempted = json!({ "namespace": "skill:profile:beta" });
    let alpha_result = alpha
        .invoke(
            "alpha-call",
            &attempted,
            broker.clone(),
            &RuntimeLimits::default(),
        )
        .unwrap();
    let beta_result = beta
        .invoke(
            "beta-call",
            &attempted,
            broker.clone(),
            &RuntimeLimits::default(),
        )
        .unwrap();
    assert_eq!(alpha_result.value["namespace"], "skill:profile:alpha");
    assert_eq!(beta_result.value["namespace"], "skill:profile:beta");
    let requests = broker.requests.lock().unwrap();
    assert_eq!(requests[0].input["namespace"], "skill:profile:alpha");
    assert_eq!(requests[1].input["namespace"], "skill:profile:beta");
}

#[test]
fn same_id_project_skills_in_distinct_workspaces_have_distinct_state_namespaces() {
    let directory = tempdir().expect("tempdir");
    let profile = directory.path().join("profile");
    let first_root = directory.path().join("project-one");
    let second_root = directory.path().join("project-two");
    write_state_skill(&first_root, "local-index");
    write_state_skill(&second_root, "local-index");
    let first = SkillCatalog::with_project_namespace(
        &profile,
        Some(first_root),
        true,
        Some("workspace-one".to_owned()),
    )
    .resolve_module("local-index", "scripts/main.ts")
    .unwrap();
    let second = SkillCatalog::with_project_namespace(
        &profile,
        Some(second_root),
        true,
        Some("workspace-two".to_owned()),
    )
    .resolve_module("local-index", "scripts/main.ts")
    .unwrap();
    assert_ne!(first.state_namespace(), second.state_namespace());
    assert!(!first.state_namespace().contains("workspace-one"));
    assert!(!second.state_namespace().contains("workspace-two"));
}

#[test]
fn capability_state_is_isolated_authorized_and_idempotent() {
    let directory = tempdir().expect("tempdir");
    let state = CapabilityState::open(directory.path()).expect("state");
    let setup = StateEffect {
        idempotency_key: "setup".to_owned(),
        statements: vec![
            StateStatement {
                sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)".to_owned(),
                parameters: vec![],
            },
            StateStatement {
                sql: "INSERT INTO notes(body) VALUES (?)".to_owned(),
                parameters: vec![json!("hello")],
            },
        ],
    };
    let first = state.execute("skill:index", &setup).expect("effect");
    assert!(!first.replayed);
    let second = state.execute("skill:index", &setup).expect("replay");
    assert!(second.replayed);
    let rows = state
        .query(
            "skill:index",
            &StateQuery {
                sql: "SELECT id, body FROM notes".to_owned(),
                parameters: vec![],
                max_rows: 10,
            },
        )
        .expect("query");
    assert_eq!(rows, vec![json!({ "id": 1, "body": "hello" })]);
    assert!(
        state
            .query(
                "skill:other",
                &StateQuery {
                    sql: "SELECT * FROM notes".to_owned(),
                    parameters: vec![],
                    max_rows: 10,
                },
            )
            .is_err()
    );
    let denied = state.query(
        "skill:index",
        &StateQuery {
            sql: "SELECT * FROM _tron_effects".to_owned(),
            parameters: vec![],
            max_rows: 10,
        },
    );
    assert!(denied.is_err());
    let attach = StateEffect {
        idempotency_key: "attach".to_owned(),
        statements: vec![StateStatement {
            sql: "ATTACH DATABASE ':memory:' AS escaped".to_owned(),
            parameters: vec![],
        }],
    };
    assert!(state.execute("skill:index", &attach).is_err());
    assert!(state.info("skill:other").unwrap().bytes > 0);
}

fn request(key: &str, source: &str) -> CodeRunRequest {
    CodeRunRequest {
        agent_id: "agent-1".to_owned(),
        invocation_key: key.to_owned(),
        assignment_id: Some("assignment-1".to_owned()),
        source: source.to_owned(),
    }
}

fn initialize_code_database(path: &std::path::Path) {
    let pool = crate::domains::session::event_store::new_file(
        &path.to_string_lossy(),
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .expect("event store database");
    let connection = pool.get().expect("event store connection");
    crate::domains::session::event_store::ensure_schema(&connection)
        .expect("canonical current schema");
}

fn write_skill(root: &std::path::Path, id: &str, name: &str, instructions: &str, marker: &str) {
    let package = root.join(id);
    fs::create_dir_all(package.join("scripts")).unwrap();
    fs::write(
        package.join("SKILL.md"),
        format!("---\nid: {id}\nname: {name}\nsummary: Test skill\n---\n{instructions}\n"),
    )
    .unwrap();
    fs::write(
        package.join("scripts/main.ts"),
        format!(
            "export default async function(_capabilities: unknown, input: unknown) {{ return {{ input, marker: '{marker}' }}; }}"
        ),
    )
    .unwrap();
}

fn write_state_skill(root: &std::path::Path, id: &str) {
    let package = root.join(id);
    fs::create_dir_all(package.join("scripts")).unwrap();
    fs::write(
        package.join("SKILL.md"),
        format!("---\nid: {id}\nname: {id}\nsummary: Stateful test\n---\nTest\n"),
    )
    .unwrap();
    fs::write(
        package.join("scripts/main.ts"),
        "export default async function({ state }: any, input: any) { return state.info(input); }",
    )
    .unwrap();
}
