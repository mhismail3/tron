use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::service::{self, Clock};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, SCHEDULE_KIND,
    SCHEDULE_RUN_KIND, TraceId,
};

#[derive(Clone, Copy)]
struct FixedClock {
    now: DateTime<Utc>,
}

impl Clock for FixedClock {
    fn now(&self) -> DateTime<Utc> {
        self.now
    }
}

fn dt(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("test timestamp")
        .with_timezone(&Utc)
}

fn invocation(key: &str, scopes: &[&str], payload: Value) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new("agent:scheduler-session").unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("scheduler-grant").unwrap(),
        TraceId::new(format!("scheduler-trace-{key}")).unwrap(),
    )
    .with_session_id("scheduler-session")
    .with_workspace_id("scheduler-workspace")
    .with_idempotency_key(key);
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation::new_sync(
        FunctionId::new("capability::execute").unwrap(),
        payload,
        context,
    )
}

fn invocation_without_context(key: &str, scopes: &[&str], payload: Value) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new("agent:scheduler-session").unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("scheduler-grant").unwrap(),
        TraceId::new(format!("scheduler-trace-{key}")).unwrap(),
    )
    .with_idempotency_key(key);
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation::new_sync(
        FunctionId::new("capability::execute").unwrap(),
        payload,
        context,
    )
}

fn create_payload(start_at: &str, policy: &str) -> Value {
    json!({
        "title": "Daily standup review",
        "scheduleKind": "automation",
        "triggerType": "interval",
        "startAt": start_at,
        "intervalSeconds": 600,
        "timezone": "UTC",
        "missedRunPolicy": policy,
        "maxCatchUpRuns": 3,
        "target": {
            "resourceKind": "goal",
            "action": "inspect",
            "resourceIds": ["goal:alpha"]
        },
        "maxRunRecords": 100,
        "maxAgeDays": 30
    })
}

fn assert_no_grant_or_token_like_leak(value: &Value) {
    fn walk(path: &str, value: &Value) {
        match value {
            Value::Object(map) => {
                for (key, child) in map {
                    let lower = key.to_ascii_lowercase();
                    assert!(
                        !lower.contains("grant") && !lower.contains("token"),
                        "grant/token-like key leaked at {path}.{key}: {value}"
                    );
                    walk(&format!("{path}.{key}"), child);
                }
            }
            Value::Array(items) => {
                for (index, child) in items.iter().enumerate() {
                    walk(&format!("{path}[{index}]"), child);
                }
            }
            Value::String(text) => {
                assert!(
                    !text.contains("scheduler-grant")
                        && !text.to_ascii_lowercase().contains("token"),
                    "grant/token-like value leaked at {path}: {text}"
                );
            }
            _ => {}
        }
    }
    walk("$", value);
}

#[tokio::test]
async fn clock_injection_fires_due_interval_and_records_catch_up_runs() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let create = invocation(
        "create-catch-up",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "catch_up"),
    );
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();
    let schedule_id = created["scheduleResourceId"].as_str().unwrap();

    let fire = invocation(
        "fire-catch-up",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 10}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:25:00Z"),
        },
    )
    .await
    .unwrap();

    assert_eq!(fired["runRecordCount"], json!(3));
    let runs = fired["runs"].as_array().unwrap();
    assert_eq!(runs[0]["scheduledFor"], json!("2026-01-01T00:00:00Z"));
    assert_eq!(runs[1]["scheduledFor"], json!("2026-01-01T00:10:00Z"));
    assert_eq!(runs[2]["scheduledFor"], json!("2026-01-01T00:20:00Z"));

    let inspect = invocation(
        "inspect-catch-up",
        &["scheduler.read"],
        json!({"scheduleResourceId": schedule_id, "limit": 10}),
    );
    let inspected = service::inspect_schedule_value(&ctx.engine_host, &inspect, &inspect.payload)
        .await
        .unwrap();
    assert_eq!(
        inspected["schedule"]["nextFireAt"],
        json!("2026-01-01T00:30:00Z")
    );
    assert_eq!(
        inspected["runs"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|run| run["state"] == "recorded")
            .count(),
        3
    );
}

#[tokio::test]
async fn missed_run_skip_records_skip_evidence_without_background_run() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let create = invocation(
        "create-skip",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "skip"),
    );
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();

    let fire = invocation(
        "fire-skip",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 10}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:25:00Z"),
        },
    )
    .await
    .unwrap();
    assert_eq!(fired["runRecordCount"], json!(1));
    assert_eq!(fired["runs"][0]["state"], json!("skipped_missed"));
    assert_eq!(
        fired["runs"][0]["missed"]["occurrencesRepresented"],
        json!(3)
    );

    let inspect = invocation(
        "inspect-skip",
        &["scheduler.read"],
        json!({"scheduleResourceId": created["scheduleResourceId"], "limit": 10}),
    );
    let inspected = service::inspect_schedule_value(&ctx.engine_host, &inspect, &inspect.payload)
        .await
        .unwrap();
    assert_eq!(
        inspected["schedule"]["nextFireAt"],
        json!("2026-01-01T00:30:00Z")
    );
    assert_eq!(inspected["schedule"]["lastRunAt"], Value::Null);
}

#[tokio::test]
async fn fire_due_handles_multiple_schedules_without_run_id_collision() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let first_create = invocation(
        "create-multi-first",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let first_created =
        service::create_schedule_value(&ctx.engine_host, &first_create, &first_create.payload)
            .await
            .unwrap();
    let second_create = invocation(
        "create-multi-second",
        &["scheduler.write"],
        create_payload("2026-01-01T00:05:00Z", "fire_once"),
    );
    let second_created =
        service::create_schedule_value(&ctx.engine_host, &second_create, &second_create.payload)
            .await
            .unwrap();

    let fire = invocation(
        "fire-multi",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 10}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:25:00Z"),
        },
    )
    .await
    .unwrap();

    assert_eq!(fired["evaluatedSchedules"], json!(2));
    assert_eq!(fired["runRecordCount"], json!(2));
    let runs = fired["runs"].as_array().unwrap();
    assert_ne!(
        runs[0]["scheduleRunResourceId"],
        runs[1]["scheduleRunResourceId"]
    );
    let fired_schedule_ids = runs
        .iter()
        .map(|run| run["scheduleResourceId"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(fired_schedule_ids.contains(&first_created["scheduleResourceId"].as_str().unwrap()));
    assert!(fired_schedule_ids.contains(&second_created["scheduleResourceId"].as_str().unwrap()));
}

#[tokio::test]
async fn cancelled_schedule_is_terminal_and_fire_due_ignores_it() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let create = invocation(
        "create-cancel",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();
    let schedule_id = created["scheduleResourceId"].as_str().unwrap();

    let cancel = invocation(
        "cancel-schedule",
        &["scheduler.write"],
        json!({"scheduleResourceId": schedule_id, "reason": "No longer needed"}),
    );
    let cancelled = service::cancel_schedule_value(&ctx.engine_host, &cancel, &cancel.payload)
        .await
        .unwrap();
    assert_eq!(cancelled["status"], json!("cancelled"));

    let fire = invocation(
        "fire-cancelled",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 10}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:25:00Z"),
        },
    )
    .await
    .unwrap();
    assert_eq!(fired["runRecordCount"], json!(0));
}

#[tokio::test]
async fn schedule_create_rejects_missing_write_scope_and_wildcard_target() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let missing_scope = invocation(
        "create-no-scope",
        &["scheduler.read"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let error =
        service::create_schedule_value(&ctx.engine_host, &missing_scope, &missing_scope.payload)
            .await
            .unwrap_err();
    assert!(error.to_string().contains("scheduler.write"));

    let wildcard_target = invocation(
        "create-wildcard",
        &["scheduler.write"],
        json!({
            "title": "Bad target",
            "triggerType": "once",
            "startAt": "2026-01-01T00:00:00Z",
            "target": {"resourceKind": "*", "action": "inspect"}
        }),
    );
    let error = service::create_schedule_value(
        &ctx.engine_host,
        &wildcard_target,
        &wildcard_target.payload,
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("non-wildcard"));
}

#[tokio::test]
async fn schedule_inspect_redacts_authority_grants_and_token_like_fields() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let create = invocation(
        "create-redaction",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();
    let schedule_id = created["scheduleResourceId"].as_str().unwrap();

    let cancel = invocation(
        "cancel-redaction",
        &["scheduler.write"],
        json!({"scheduleResourceId": schedule_id, "reason": "Redaction coverage"}),
    );
    service::cancel_schedule_value(&ctx.engine_host, &cancel, &cancel.payload)
        .await
        .unwrap();

    let inspect = invocation(
        "inspect-redaction",
        &["scheduler.read"],
        json!({"scheduleResourceId": schedule_id, "limit": 10}),
    );
    let inspected = service::inspect_schedule_value(&ctx.engine_host, &inspect, &inspect.payload)
        .await
        .unwrap();

    assert_eq!(inspected["schedule"]["state"], json!("cancelled"));
    assert!(inspected["schedule"].get("authority").is_none());
    assert!(
        inspected["schedule"]["cancellation"]
            .get("idempotency")
            .is_none()
    );
    assert_no_grant_or_token_like_leak(&inspected);
}

#[tokio::test]
async fn fire_due_uses_bounded_candidate_window_independent_of_total_schedules() {
    let ctx = crate::shared::server::test_support::make_test_context();
    for index in 0..105 {
        let create = invocation(
            &format!("create-bounded-fire-{index}"),
            &["scheduler.write"],
            create_payload("2026-01-01T00:00:00Z", "fire_once"),
        );
        service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
            .await
            .unwrap();
    }

    let fire = invocation(
        "fire-bounded-window",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 100}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:01:00Z"),
        },
    )
    .await
    .unwrap();

    assert_eq!(fired["candidateLimit"], json!(100));
    assert_eq!(fired["candidateScheduleCount"], json!(100));
    assert_eq!(fired["evaluatedSchedules"], json!(50));
    assert_eq!(fired["runRecordCount"], json!(50));
}

#[tokio::test]
async fn schedule_inspect_uses_bounded_run_links_independent_of_total_runs() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let mut payload = create_payload("2026-01-01T00:00:00Z", "catch_up");
    payload["intervalSeconds"] = json!(60);
    payload["maxCatchUpRuns"] = json!(40);
    let create = invocation("create-bounded-runs", &["scheduler.write"], payload);
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();
    let schedule_id = created["scheduleResourceId"].as_str().unwrap();

    let fire = invocation(
        "fire-bounded-runs",
        &["scheduler.write", "scheduler.fire"],
        json!({"limit": 10}),
    );
    let fired = service::fire_due_schedules_with_clock(
        &ctx.engine_host,
        &fire,
        &fire.payload,
        &FixedClock {
            now: dt("2026-01-01T00:39:00Z"),
        },
    )
    .await
    .unwrap();
    assert_eq!(fired["runRecordCount"], json!(40));

    let inspect = invocation(
        "inspect-bounded-runs",
        &["scheduler.read"],
        json!({"scheduleResourceId": schedule_id, "limit": 5}),
    );
    let inspected = service::inspect_schedule_value(&ctx.engine_host, &inspect, &inspect.payload)
        .await
        .unwrap();
    let runs = inspected["runs"].as_array().unwrap();

    assert_eq!(inspected["runLimit"], json!(5));
    assert_eq!(runs.len(), 5);
    assert!(
        runs.iter()
            .all(|run| run["scheduleResourceId"] == schedule_id)
    );
}

#[tokio::test]
async fn scheduler_service_rejects_missing_session_or_workspace_context() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let create = invocation(
        "create-context",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let created = service::create_schedule_value(&ctx.engine_host, &create, &create.payload)
        .await
        .unwrap();
    let schedule_id = created["scheduleResourceId"].as_str().unwrap();

    let no_context_create = invocation_without_context(
        "create-no-context",
        &["scheduler.write"],
        create_payload("2026-01-01T00:00:00Z", "fire_once"),
    );
    let error = service::create_schedule_value(
        &ctx.engine_host,
        &no_context_create,
        &no_context_create.payload,
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("trusted current session or workspace")
    );

    let no_context_list =
        invocation_without_context("list-no-context", &["scheduler.read"], json!({"limit": 10}));
    let error =
        service::list_schedules_value(&ctx.engine_host, &no_context_list, &no_context_list.payload)
            .await
            .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("trusted current session or workspace")
    );

    let no_context_inspect = invocation_without_context(
        "inspect-no-context",
        &["scheduler.read"],
        json!({"scheduleResourceId": schedule_id}),
    );
    let error = service::inspect_schedule_value(
        &ctx.engine_host,
        &no_context_inspect,
        &no_context_inspect.payload,
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("trusted current session or workspace")
    );

    let no_context_cancel = invocation_without_context(
        "cancel-no-context",
        &["scheduler.write"],
        json!({"scheduleResourceId": schedule_id, "reason": "No context"}),
    );
    let error = service::cancel_schedule_value(
        &ctx.engine_host,
        &no_context_cancel,
        &no_context_cancel.payload,
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("trusted current session or workspace")
    );

    let no_context_fire = invocation_without_context(
        "fire-no-context",
        &["scheduler.write", "scheduler.fire"],
        json!({"evaluationAt": "2026-01-01T00:01:00Z"}),
    );
    let error = service::fire_due_schedules_value(
        &ctx.engine_host,
        &no_context_fire,
        &no_context_fire.payload,
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("trusted current session or workspace")
    );
}

#[test]
fn scheduler_resource_definitions_register_schedule_and_run_schemas() {
    let definitions = crate::engine::builtin_resource_type_definitions();
    let schedule = definitions
        .iter()
        .find(|definition| definition.kind == SCHEDULE_KIND)
        .expect("schedule kind");
    assert_eq!(schedule.schema_id, "tron.resource.schedule.v1");
    assert!(
        schedule
            .required_capabilities
            .to_string()
            .contains("scheduler.fire")
    );
    let run = definitions
        .iter()
        .find(|definition| definition.kind == SCHEDULE_RUN_KIND)
        .expect("schedule_run kind");
    assert_eq!(run.schema_id, "tron.resource.schedule_run.v1");
    assert!(run.lifecycle_states.iter().any(|state| state == "recorded"));
}
