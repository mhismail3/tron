use std::sync::Arc;

use chrono::{Duration, TimeZone, Utc};

use super::contract::{
    MisfirePolicy, OccurrenceState, OverlapPolicy, ScheduleAction, ScheduleAuthoritySnapshot,
    SchedulePatch, SchedulePolicy, ScheduleResponse, ScheduleState, ScheduleTarget, ScheduleTiming,
    ScheduledAgentDefaults, ScheduledAssignment,
};
use super::recurrence::{RecurrenceError, expand_window, validate_timing};
use super::service::{ScheduleError, ScheduleService};
use crate::domains::session::event_store::{
    ConnectionConfig, EventStore, ensure_schema, new_in_memory,
};

fn instant(
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, second)
        .unwrap()
}

fn setup() -> ScheduleService {
    let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
    ensure_schema(&pool.get().unwrap()).unwrap();
    ScheduleService::new(Arc::new(EventStore::new(pool)))
}

fn recurring(rule: &str) -> ScheduleTiming {
    ScheduleTiming::Recurring {
        start_local: "2026-01-01T09:15:30".to_owned(),
        time_zone: "America/Los_Angeles".to_owned(),
        rrule: rule.to_owned(),
        rdates: Vec::new(),
        exdates: Vec::new(),
    }
}

fn create_action(idempotency_key: &str, policy: SchedulePolicy) -> ScheduleAction {
    ScheduleAction::Create {
        idempotency_key: idempotency_key.to_owned(),
        owner_agent_id: "agent_owner".to_owned(),
        name: "Morning review".to_owned(),
        target: ScheduleTarget::ReusableAgent {
            agent_id: "agent_target".to_owned(),
            assignment: ScheduledAssignment {
                task: "Review the durable queue and report findings.".to_owned(),
                context: serde_json::json!({"source":"schedule"}),
            },
        },
        authority: ScheduleAuthoritySnapshot {
            principal_agent_id: "agent_owner".to_owned(),
            grant: serde_json::json!({"assign":["agent_target"]}),
        },
        timing: recurring("FREQ=DAILY"),
        policy,
    }
}

fn created(response: ScheduleResponse) -> super::contract::ScheduleRecord {
    match response {
        ScheduleResponse::Create { schedule } => schedule,
        other => panic!("expected create response, got {other:?}"),
    }
}

#[test]
fn validates_every_standard_rrule_part() {
    let fixtures = [
        ("BYSECOND", "FREQ=MINUTELY;COUNT=3;BYSECOND=10,30"),
        ("BYMINUTE", "FREQ=HOURLY;COUNT=3;BYMINUTE=5,35"),
        ("BYHOUR", "FREQ=DAILY;COUNT=3;BYHOUR=8,16"),
        ("BYDAY", "FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE;WKST=SU"),
        ("BYMONTHDAY", "FREQ=MONTHLY;COUNT=3;BYMONTHDAY=1,-1"),
        ("BYYEARDAY", "FREQ=YEARLY;COUNT=3;BYYEARDAY=1,-1"),
        ("BYWEEKNO", "FREQ=YEARLY;COUNT=3;BYWEEKNO=1,-1;BYDAY=MO"),
        ("BYMONTH", "FREQ=YEARLY;COUNT=3;BYMONTH=2,8"),
        (
            "BYSETPOS",
            "FREQ=MONTHLY;COUNT=3;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
        ),
    ];

    for (part, rule) in fixtures {
        let validated = validate_timing(&recurring(rule)).unwrap();
        let ScheduleTiming::Recurring { ref rrule, .. } = validated.timing else {
            panic!("expected recurring timing")
        };
        assert!(
            rrule.contains(part),
            "canonical rule omitted {part}: {rrule}"
        );
        let expansion = expand_window(
            &validated.timing,
            instant(2025, 12, 31, 0, 0, 0),
            instant(2030, 1, 1, 0, 0, 0),
        )
        .unwrap();
        assert!(
            !expansion.due.is_empty(),
            "fixture produced no {part} dates"
        );
    }
}

#[test]
fn preserves_wall_clock_time_across_dst() {
    let timing = ScheduleTiming::Recurring {
        start_local: "2026-03-07T09:00:00".to_owned(),
        time_zone: "America/Los_Angeles".to_owned(),
        rrule: "FREQ=DAILY;COUNT=3".to_owned(),
        rdates: Vec::new(),
        exdates: Vec::new(),
    };
    let timing = validate_timing(&timing).unwrap().timing;
    let expansion = expand_window(
        &timing,
        instant(2026, 3, 7, 0, 0, 0),
        instant(2026, 3, 10, 0, 0, 0),
    )
    .unwrap();
    assert_eq!(
        expansion
            .due
            .iter()
            .map(chrono::DateTime::to_rfc3339)
            .collect::<Vec<_>>(),
        [
            "2026-03-07T17:00:00+00:00",
            "2026-03-08T16:00:00+00:00",
            "2026-03-09T16:00:00+00:00",
        ]
    );
}

#[test]
fn rejects_ambiguous_local_start_and_nonstandard_rule_forms() {
    let ambiguous = ScheduleTiming::Recurring {
        start_local: "2026-11-01T01:30:00".to_owned(),
        time_zone: "America/Los_Angeles".to_owned(),
        rrule: "FREQ=DAILY;COUNT=2".to_owned(),
        rdates: Vec::new(),
        exdates: Vec::new(),
    };
    assert!(matches!(
        validate_timing(&ambiguous),
        Err(RecurrenceError::InvalidRule(_))
    ));
    assert!(matches!(
        validate_timing(&recurring("FREQ=YEARLY;BYEASTER=0")),
        Err(RecurrenceError::InvalidRule(_))
    ));
    assert!(matches!(
        validate_timing(&recurring("FREQ=DAILY\nEXRULE:FREQ=WEEKLY")),
        Err(RecurrenceError::BoundExceeded(_) | RecurrenceError::InvalidRule(_))
    ));
}

#[test]
fn rdates_and_exdates_use_the_schedule_timezone() {
    let timing = ScheduleTiming::Recurring {
        start_local: "2026-01-01T09:00:00".to_owned(),
        time_zone: "America/New_York".to_owned(),
        rrule: "FREQ=DAILY;COUNT=2".to_owned(),
        rdates: vec!["2026-01-03T09:00:00".to_owned()],
        exdates: vec!["2026-01-02T09:00:00".to_owned()],
    };
    let timing = validate_timing(&timing).unwrap().timing;
    let expansion = expand_window(
        &timing,
        instant(2026, 1, 1, 0, 0, 0),
        instant(2026, 1, 4, 0, 0, 0),
    )
    .unwrap();
    assert_eq!(
        expansion.due,
        [instant(2026, 1, 1, 14, 0, 0), instant(2026, 1, 3, 14, 0, 0)]
    );
}

#[test]
fn explicit_date_and_expansion_bounds_fail_closed() {
    let too_many_dates = ScheduleTiming::Recurring {
        start_local: "2026-01-01T00:00:00".to_owned(),
        time_zone: "UTC".to_owned(),
        rrule: "FREQ=DAILY".to_owned(),
        rdates: vec!["2026-01-02T00:00:00".to_owned(); 257],
        exdates: Vec::new(),
    };
    assert!(matches!(
        validate_timing(&too_many_dates),
        Err(RecurrenceError::BoundExceeded(_))
    ));

    let dense = ScheduleTiming::Recurring {
        start_local: "2020-01-01T00:00:00".to_owned(),
        time_zone: "UTC".to_owned(),
        rrule: "FREQ=SECONDLY".to_owned(),
        rdates: Vec::new(),
        exdates: Vec::new(),
    };
    let dense = validate_timing(&dense).unwrap().timing;
    assert!(matches!(
        expand_window(
            &dense,
            instant(2021, 1, 1, 0, 0, 0),
            instant(2021, 1, 1, 0, 0, 1)
        ),
        Err(RecurrenceError::BoundExceeded(_))
    ));
}

#[test]
fn create_is_idempotent_and_revision_transitions_are_strict() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let first = created(
        service
            .execute_at(create_action("create-1", SchedulePolicy::default()), now)
            .unwrap(),
    );
    let replay = created(
        service
            .execute_at(create_action("create-1", SchedulePolicy::default()), now)
            .unwrap(),
    );
    assert_eq!(first.schedule_id, replay.schedule_id);

    let mut changed = create_action("create-1", SchedulePolicy::default());
    let ScheduleAction::Create { name, .. } = &mut changed else {
        unreachable!()
    };
    *name = "Different".to_owned();
    assert!(service.execute_at(changed, now).is_err());

    let paused = service
        .execute_at(
            ScheduleAction::Pause {
                schedule_id: first.schedule_id.clone(),
                expected_revision: 1,
            },
            now + Duration::seconds(1),
        )
        .unwrap();
    let ScheduleResponse::Pause { schedule: paused } = paused else {
        panic!("expected pause")
    };
    assert_eq!(paused.state, ScheduleState::Paused);
    assert_eq!(paused.revision, 2);
    assert!(matches!(
        service.execute_at(
            ScheduleAction::Resume {
                schedule_id: first.schedule_id,
                expected_revision: 1
            },
            now
        ),
        Err(ScheduleError::RevisionConflict { .. })
    ));
    let ScheduleResponse::List { page } = service
        .execute(ScheduleAction::List {
            owner_agent_id: Some("agent_owner".to_owned()),
            include_deleted: false,
            cursor: None,
            limit: Some(10),
        })
        .unwrap()
    else {
        panic!("expected list")
    };
    assert_eq!(page.schedules.len(), 1);
}

#[test]
fn unauthorized_agent_cannot_mutate_or_run_an_owned_schedule() {
    let service = setup();
    let schedule = created(
        service
            .execute_at(
                create_action("owner-bound", SchedulePolicy::default()),
                instant(2026, 1, 1, 0, 0, 0),
            )
            .unwrap(),
    );
    for action in [
        ScheduleAction::Pause {
            schedule_id: schedule.schedule_id.clone(),
            expected_revision: schedule.revision,
        },
        ScheduleAction::Delete {
            schedule_id: schedule.schedule_id.clone(),
            expected_revision: schedule.revision,
        },
        ScheduleAction::RunNow {
            schedule_id: schedule.schedule_id.clone(),
            idempotency_key: "unauthorized-run".to_owned(),
        },
    ] {
        assert!(service.execute_for_agent(action, "agent_intruder").is_err());
    }
    let ScheduleResponse::Get { detail } = service
        .execute(ScheduleAction::Get {
            schedule_id: schedule.schedule_id,
            occurrence_limit: Some(10),
        })
        .unwrap()
    else {
        panic!("expected detail")
    };
    assert_eq!(detail.schedule.revision, 1);
    assert_eq!(detail.schedule.state, ScheduleState::Active);
    assert!(detail.occurrences.is_empty());
}

#[test]
fn restart_reconciliation_admits_run_once_exactly_once() {
    let service = setup();
    let now = instant(2026, 1, 1, 9, 15, 30);
    let schedule = created(
        service
            .execute_at(
                create_action("create-reconcile", SchedulePolicy::default()),
                now,
            )
            .unwrap(),
    );
    let wake = instant(2026, 1, 4, 12, 0, 0);
    let report = service.reconcile_due(wake).unwrap();
    assert_eq!(report.schedules_considered, 1);
    assert_eq!(report.occurrences_recorded, 2);
    assert_eq!(service.reconcile_due(wake).unwrap().occurrences_recorded, 0);

    let ScheduleResponse::Get { detail } = service
        .execute_at(
            ScheduleAction::Get {
                schedule_id: schedule.schedule_id,
                occurrence_limit: Some(10),
            },
            wake,
        )
        .unwrap()
    else {
        panic!("expected detail")
    };
    assert_eq!(detail.occurrences.len(), 2);
    assert_eq!(
        detail
            .occurrences
            .iter()
            .filter(|row| row.state == OccurrenceState::Queued)
            .count(),
        1
    );
    assert_eq!(
        detail
            .occurrences
            .iter()
            .find(|row| row.state == OccurrenceState::Skipped)
            .unwrap()
            .missed_count,
        2
    );
}

#[test]
fn skip_and_bounded_catch_up_misfires_have_complete_compact_audit() {
    for (misfire, expected_queued, expected_skipped) in
        [(MisfirePolicy::Skip, 0, 3), (MisfirePolicy::CatchUp, 2, 1)]
    {
        let service = setup();
        let now = instant(2026, 1, 1, 9, 15, 30);
        let policy = SchedulePolicy {
            misfire,
            overlap: OverlapPolicy::Queue,
            max_catch_up: 2,
        };
        let schedule = created(
            service
                .execute_at(create_action("create-misfire", policy), now)
                .unwrap(),
        );
        let wake = instant(2026, 1, 4, 12, 0, 0);
        service.reconcile_due(wake).unwrap();
        let ScheduleResponse::Get { detail } = service
            .execute_at(
                ScheduleAction::Get {
                    schedule_id: schedule.schedule_id,
                    occurrence_limit: Some(10),
                },
                wake,
            )
            .unwrap()
        else {
            panic!("expected detail")
        };
        assert_eq!(
            detail
                .occurrences
                .iter()
                .filter(|row| row.state == OccurrenceState::Queued)
                .count(),
            expected_queued
        );
        assert_eq!(
            detail
                .occurrences
                .iter()
                .filter(|row| row.state == OccurrenceState::Skipped)
                .map(|row| row.missed_count)
                .sum::<u64>(),
            expected_skipped
        );
    }
}

#[test]
fn one_time_schedule_exhausts_after_exactly_one_occurrence() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let due = now + Duration::minutes(5);
    let schedule = created(
        service
            .execute_at(
                ScheduleAction::Create {
                    idempotency_key: "create-once".to_owned(),
                    owner_agent_id: "agent_owner".to_owned(),
                    name: "One time".to_owned(),
                    target: ScheduleTarget::ReusableAgent {
                        agent_id: "agent_target".to_owned(),
                        assignment: ScheduledAssignment {
                            task: "Run once.".to_owned(),
                            context: serde_json::Value::Null,
                        },
                    },
                    authority: ScheduleAuthoritySnapshot {
                        principal_agent_id: "agent_owner".to_owned(),
                        grant: serde_json::json!({"assign":["agent_target"]}),
                    },
                    timing: ScheduleTiming::Once {
                        at: due.to_rfc3339(),
                    },
                    policy: SchedulePolicy::default(),
                },
                now,
            )
            .unwrap(),
    );
    assert_eq!(service.reconcile_due(due).unwrap().occurrences_recorded, 1);
    assert_eq!(service.reconcile_due(due).unwrap().occurrences_recorded, 0);
    let ScheduleResponse::Get { detail } = service
        .execute_at(
            ScheduleAction::Get {
                schedule_id: schedule.schedule_id,
                occurrence_limit: Some(5),
            },
            due,
        )
        .unwrap()
    else {
        panic!("expected detail")
    };
    assert!(detail.schedule.next_due_at.is_none());
    assert_eq!(detail.occurrences.len(), 1);
}

#[test]
fn overlap_skip_and_expired_lease_recovery_are_durable() {
    let service = setup();
    let now = instant(2026, 1, 1, 9, 15, 30);
    let policy = SchedulePolicy {
        misfire: MisfirePolicy::RunOnce,
        overlap: OverlapPolicy::Skip,
        max_catch_up: 32,
    };
    let schedule = created(
        service
            .execute_at(create_action("create-overlap", policy), now)
            .unwrap(),
    );
    service
        .execute_at(
            ScheduleAction::RunNow {
                schedule_id: schedule.schedule_id.clone(),
                idempotency_key: "manual-one".to_owned(),
            },
            now,
        )
        .unwrap();
    let ScheduleResponse::RunNow { occurrence } = service
        .execute_at(
            ScheduleAction::RunNow {
                schedule_id: schedule.schedule_id,
                idempotency_key: "manual-two".to_owned(),
            },
            now + Duration::seconds(1),
        )
        .unwrap()
    else {
        panic!("expected run_now")
    };
    assert_eq!(occurrence.state, OccurrenceState::Skipped);

    let claimed = service
        .claim_next("dispatcher-a", now, Duration::seconds(10))
        .unwrap()
        .unwrap();
    assert_eq!(claimed.state, OccurrenceState::Running);
    let reclaimed = service
        .claim_next(
            "dispatcher-b",
            now + Duration::seconds(11),
            Duration::seconds(10),
        )
        .unwrap()
        .unwrap();
    assert!(
        service
            .bind_agent_assignment(
                &reclaimed.occurrence_id,
                "dispatcher-b",
                "agent_target",
                "assignment_scheduled",
            )
            .unwrap()
    );
    assert!(
        service
            .terminalize(
                &reclaimed.occurrence_id,
                "dispatcher-b",
                false,
                None,
                Some("provider unavailable"),
                now + Duration::seconds(12),
            )
            .unwrap()
    );
}

#[test]
fn update_run_now_and_delete_keep_occurrence_audit() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let schedule = created(
        service
            .execute_at(
                create_action("create-update", SchedulePolicy::default()),
                now,
            )
            .unwrap(),
    );
    let ScheduleResponse::Update { schedule } = service
        .execute_at(
            ScheduleAction::Update {
                schedule_id: schedule.schedule_id,
                expected_revision: 1,
                patch: SchedulePatch {
                    name: Some("A revised durable schedule.".to_owned()),
                    ..SchedulePatch::default()
                },
            },
            now + Duration::seconds(1),
        )
        .unwrap()
    else {
        panic!("expected update")
    };
    let first = service
        .execute_at(
            ScheduleAction::RunNow {
                schedule_id: schedule.schedule_id.clone(),
                idempotency_key: "run-exactly-once".to_owned(),
            },
            now + Duration::seconds(2),
        )
        .unwrap();
    let replay = service
        .execute_at(
            ScheduleAction::RunNow {
                schedule_id: schedule.schedule_id.clone(),
                idempotency_key: "run-exactly-once".to_owned(),
            },
            now + Duration::seconds(3),
        )
        .unwrap();
    assert_eq!(first, replay);
    let ScheduleResponse::Delete { schedule } = service
        .execute_at(
            ScheduleAction::Delete {
                schedule_id: schedule.schedule_id.clone(),
                expected_revision: 2,
            },
            now + Duration::seconds(4),
        )
        .unwrap()
    else {
        panic!("expected delete")
    };
    assert_eq!(schedule.state, ScheduleState::Deleted);
    let ScheduleResponse::Get { detail } = service
        .execute_at(
            ScheduleAction::Get {
                schedule_id: schedule.schedule_id,
                occurrence_limit: Some(10),
            },
            now,
        )
        .unwrap()
    else {
        panic!("expected detail")
    };
    assert_eq!(detail.occurrences.len(), 1);
}

#[test]
fn substrate_neutral_targets_pin_authority_and_capability_version() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let capability = ScheduleAction::Create {
        idempotency_key: "create-capability".to_owned(),
        owner_agent_id: "agent_owner".to_owned(),
        name: "Send digest".to_owned(),
        target: ScheduleTarget::Capability {
            capability_id: "service:notifications.send".to_owned(),
            capability_version: Some("v1".to_owned()),
            input: serde_json::json!({"template":"daily_digest"}),
        },
        authority: ScheduleAuthoritySnapshot {
            principal_agent_id: "agent_owner".to_owned(),
            grant: serde_json::json!({
                "capabilities":["service:notifications.send@v1"]
            }),
        },
        timing: ScheduleTiming::Once {
            at: (now + Duration::hours(1)).to_rfc3339(),
        },
        policy: SchedulePolicy::default(),
    };
    let schedule = created(service.execute_at(capability, now).unwrap());
    let ScheduleTarget::Capability {
        capability_id,
        capability_version,
        ..
    } = schedule.target
    else {
        panic!("expected capability target")
    };
    assert_eq!(capability_id, "service:notifications.send");
    assert_eq!(capability_version.as_deref(), Some("v1"));
    assert_eq!(schedule.authority.principal_agent_id, "agent_owner");

    let fresh = ScheduleAction::Create {
        idempotency_key: "create-fresh-agent".to_owned(),
        owner_agent_id: "agent_owner".to_owned(),
        name: "Fresh audit".to_owned(),
        target: ScheduleTarget::FreshAgent {
            parent_agent_id: "agent_owner".to_owned(),
            name: Some("Daily auditor".to_owned()),
            defaults: Some(ScheduledAgentDefaults::default()),
            assignment: ScheduledAssignment {
                task: "Audit new evidence.".to_owned(),
                context: serde_json::json!({}),
            },
        },
        authority: ScheduleAuthoritySnapshot {
            principal_agent_id: "agent_owner".to_owned(),
            grant: serde_json::json!({"spawn":true}),
        },
        timing: recurring("FREQ=DAILY"),
        policy: SchedulePolicy::default(),
    };
    assert!(service.execute_at(fresh, now).is_ok());
}

#[test]
fn retargeting_requires_new_exact_authority_and_namespaced_capabilities() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let schedule = created(
        service
            .execute_at(
                create_action("create-retarget", SchedulePolicy::default()),
                now,
            )
            .unwrap(),
    );
    let target = ScheduleTarget::Capability {
        capability_id: "not_namespaced".to_owned(),
        capability_version: None,
        input: serde_json::Value::Null,
    };
    assert!(
        service
            .execute_at(
                ScheduleAction::Update {
                    schedule_id: schedule.schedule_id.clone(),
                    expected_revision: 1,
                    patch: SchedulePatch {
                        target: Some(target.clone()),
                        authority: Some(schedule.authority.clone()),
                        ..SchedulePatch::default()
                    },
                },
                now,
            )
            .is_err()
    );
    assert!(
        service
            .execute_at(
                ScheduleAction::Update {
                    schedule_id: schedule.schedule_id,
                    expected_revision: 1,
                    patch: SchedulePatch {
                        target: Some(ScheduleTarget::Capability {
                            capability_id: "script:knowledge/index".to_owned(),
                            capability_version: Some("sha256:fixed".to_owned()),
                            input: serde_json::json!({"path":"notes"}),
                        }),
                        authority: None,
                        ..SchedulePatch::default()
                    },
                },
                now,
            )
            .is_err()
    );
}

#[test]
fn capability_execution_lease_and_output_reference_survive_restart_boundaries() {
    let service = setup();
    let now = instant(2026, 1, 1, 0, 0, 0);
    let schedule = created(
        service
            .execute_at(
                ScheduleAction::Create {
                    idempotency_key: "create-capability-run".to_owned(),
                    owner_agent_id: "agent_owner".to_owned(),
                    name: "Transcribe capture".to_owned(),
                    target: ScheduleTarget::Capability {
                        capability_id: "service:transcription.transcribe".to_owned(),
                        capability_version: Some("v1".to_owned()),
                        input: serde_json::json!({"resource":"tron://blob/audio"}),
                    },
                    authority: ScheduleAuthoritySnapshot {
                        principal_agent_id: "agent_owner".to_owned(),
                        grant: serde_json::json!({
                            "capabilities":["service:transcription.transcribe@v1"]
                        }),
                    },
                    timing: ScheduleTiming::Once {
                        at: (now + Duration::hours(1)).to_rfc3339(),
                    },
                    policy: SchedulePolicy::default(),
                },
                now,
            )
            .unwrap(),
    );
    service
        .execute_at(
            ScheduleAction::RunNow {
                schedule_id: schedule.schedule_id.clone(),
                idempotency_key: "manual-capability".to_owned(),
            },
            now,
        )
        .unwrap();
    let claimed = service
        .claim_next("dispatcher", now, Duration::seconds(30))
        .unwrap()
        .unwrap();
    assert!(
        service
            .bind_capability_invocation(
                &claimed.occurrence_id,
                "dispatcher",
                "invocation_transcription"
            )
            .unwrap()
    );
    assert!(
        service
            .renew_lease(
                &claimed.occurrence_id,
                "dispatcher",
                now + Duration::seconds(60)
            )
            .unwrap()
    );
    assert!(
        service
            .terminalize(
                &claimed.occurrence_id,
                "dispatcher",
                true,
                Some("tron://result/transcript"),
                None,
                now + Duration::seconds(2),
            )
            .unwrap()
    );

    let ScheduleResponse::Get { detail } = service
        .execute_at(
            ScheduleAction::Get {
                schedule_id: schedule.schedule_id,
                occurrence_limit: Some(5),
            },
            now,
        )
        .unwrap()
    else {
        panic!("expected detail")
    };
    assert_eq!(detail.occurrences[0].state, OccurrenceState::Completed);
    assert_eq!(
        detail.occurrences[0].invocation_id.as_deref(),
        Some("invocation_transcription")
    );
    assert_eq!(
        detail.occurrences[0].output_ref.as_deref(),
        Some("tron://result/transcript")
    );
}
