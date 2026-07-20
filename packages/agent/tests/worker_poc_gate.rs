//! Empirical completion gate for the permissive worker-first POC.
//!
//! The committed ledger is intentionally empty: CI verifies the gate logic but
//! does not fabricate real-world evidence. After testing, copy the fixture to a
//! local writable path, append observations, and run the ignored gate with
//! `TRON_WORKER_POC_LEDGER=/absolute/path cargo test --test worker_poc_gate worker_poc_empirical_gate -- --ignored`.

use std::collections::{BTreeSet, HashSet};
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Ledger {
    format: String,
    criteria: Criteria,
    observations: Vec<Observation>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Criteria {
    minimum_substantive_scenarios: usize,
    minimum_distinct_days: usize,
    minimum_autonomous_adaptations: usize,
    #[serde(default = "default_minimum_proactive_adaptations")]
    minimum_proactive_adaptations: usize,
    prohibited_unresolved_failure_causes: BTreeSet<String>,
}

const fn default_minimum_proactive_adaptations() -> usize {
    1
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Observation {
    id: String,
    completed_at: DateTime<Utc>,
    summary: String,
    substantive: bool,
    autonomous_adaptation: bool,
    #[serde(default)]
    proactive_adaptation: bool,
    status: ObservationStatus,
    #[serde(default)]
    failure_cause: Option<String>,
    #[serde(default)]
    resolved: bool,
    #[serde(default)]
    resolved_at: Option<DateTime<Utc>>,
    #[serde(default)]
    resolution_evidence: Vec<String>,
    evidence: Vec<String>,
    #[serde(default)]
    notes: Vec<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum ObservationStatus {
    #[serde(rename = "passed", alias = "succeeded")]
    Passed,
    #[serde(rename = "failed")]
    Failed,
}

fn read_ledger(path: &Path) -> Ledger {
    serde_json::from_slice(&std::fs::read(path).expect("read worker POC ledger"))
        .expect("decode worker POC ledger")
}

fn gate_errors(ledger: &Ledger) -> Vec<String> {
    let mut errors = Vec::new();
    if ledger.format != "tron.worker_poc_observations.v1" {
        errors.push(format!("unsupported ledger format {}", ledger.format));
    }

    let unique_ids = ledger
        .observations
        .iter()
        .map(|observation| observation.id.as_str())
        .collect::<HashSet<_>>();
    if unique_ids.len() != ledger.observations.len() {
        errors.push("observation ids must be unique".to_owned());
    }

    for observation in &ledger.observations {
        if observation.summary.trim().is_empty() {
            errors.push(format!("observation {} has no summary", observation.id));
        }
        if observation.evidence.is_empty()
            || observation
                .evidence
                .iter()
                .any(|item| item.trim().is_empty())
        {
            errors.push(format!(
                "observation {} requires concrete non-empty evidence refs",
                observation.id
            ));
        }
        if observation.notes.iter().any(|item| item.trim().is_empty()) {
            errors.push(format!(
                "observation {} contains an empty note",
                observation.id
            ));
        }
        if observation.proactive_adaptation && !observation.autonomous_adaptation {
            errors.push(format!(
                "observation {} cannot be proactive without an autonomous adaptation",
                observation.id
            ));
        }
        if observation.status == ObservationStatus::Failed
            && observation
                .failure_cause
                .as_deref()
                .is_none_or(str::is_empty)
        {
            errors.push(format!(
                "failed observation {} requires a failure cause",
                observation.id
            ));
        }
        if observation.status == ObservationStatus::Failed
            && observation.resolved
            && (observation.resolved_at.is_none()
                || observation.resolution_evidence.is_empty()
                || observation
                    .resolution_evidence
                    .iter()
                    .any(|item| item.trim().is_empty()))
        {
            errors.push(format!(
                "resolved failure {} requires resolvedAt and concrete resolutionEvidence",
                observation.id
            ));
        }
        if observation.status == ObservationStatus::Failed
            && !observation.resolved
            && observation.failure_cause.as_ref().is_some_and(|cause| {
                ledger
                    .criteria
                    .prohibited_unresolved_failure_causes
                    .contains(cause)
            })
        {
            errors.push(format!(
                "observation {} has unresolved prohibited failure cause {}",
                observation.id,
                observation.failure_cause.as_deref().unwrap_or_default()
            ));
        }
    }

    let passed = ledger
        .observations
        .iter()
        .filter(|observation| {
            observation.status == ObservationStatus::Passed && observation.substantive
        })
        .collect::<Vec<_>>();
    if passed.len() < ledger.criteria.minimum_substantive_scenarios {
        errors.push(format!(
            "requires {} substantive passed scenarios; found {}",
            ledger.criteria.minimum_substantive_scenarios,
            passed.len()
        ));
    }
    let days = passed
        .iter()
        .map(|observation| observation.completed_at.date_naive())
        .collect::<BTreeSet<_>>();
    if days.len() < ledger.criteria.minimum_distinct_days {
        errors.push(format!(
            "requires {} distinct testing days; found {}",
            ledger.criteria.minimum_distinct_days,
            days.len()
        ));
    }
    let autonomous = passed
        .iter()
        .filter(|observation| observation.autonomous_adaptation)
        .count();
    if autonomous < ledger.criteria.minimum_autonomous_adaptations {
        errors.push(format!(
            "requires {} autonomous worker creations or improvements; found {}",
            ledger.criteria.minimum_autonomous_adaptations, autonomous
        ));
    }
    let proactive = passed
        .iter()
        .filter(|observation| observation.proactive_adaptation)
        .count();
    if proactive < ledger.criteria.minimum_proactive_adaptations {
        errors.push(format!(
            "requires {} proactive worker creations or improvements; found {}",
            ledger.criteria.minimum_proactive_adaptations, proactive
        ));
    }
    errors
}

#[test]
fn committed_empirical_ledger_stays_open_until_real_observations_exist() {
    let ledger = read_ledger(Path::new(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/worker_poc_observations.json"
    )));
    let errors = gate_errors(&ledger);
    assert!(
        errors
            .iter()
            .any(|error| error.contains("10 substantive passed scenarios"))
    );
    assert!(
        errors
            .iter()
            .any(|error| error.contains("3 distinct testing days"))
    );
    assert!(
        errors
            .iter()
            .any(|error| error.contains("3 autonomous worker creations"))
    );
    assert!(
        errors
            .iter()
            .any(|error| error.contains("1 proactive worker creations"))
    );
}

#[test]
fn gate_accepts_only_evidenced_multi_day_autonomous_proof() {
    let observations = (0..10)
        .map(|index| Observation {
            id: format!("scenario-{index}"),
            completed_at: DateTime::parse_from_rfc3339(&format!(
                "2026-07-{:02}T12:00:00Z",
                17 + index % 3
            ))
            .unwrap()
            .with_timezone(&Utc),
            summary: format!("Substantive scenario {index}"),
            substantive: true,
            autonomous_adaptation: index < 3,
            proactive_adaptation: index == 0,
            status: ObservationStatus::Passed,
            failure_cause: None,
            resolved: false,
            resolved_at: None,
            resolution_evidence: Vec::new(),
            evidence: vec![format!("inbox:scenario-{index}")],
            notes: Vec::new(),
        })
        .collect();
    let ledger = Ledger {
        format: "tron.worker_poc_observations.v1".to_owned(),
        criteria: Criteria {
            minimum_substantive_scenarios: 10,
            minimum_distinct_days: 3,
            minimum_autonomous_adaptations: 3,
            minimum_proactive_adaptations: 1,
            prohibited_unresolved_failure_causes: BTreeSet::from([
                "authority_ceremony".to_owned(),
                "hidden_actuator".to_owned(),
                "proposal_only_transition".to_owned(),
                "valid_worker_activation_blocked".to_owned(),
            ]),
        },
        observations,
    };
    assert!(gate_errors(&ledger).is_empty());
}

#[test]
fn gate_accepts_rich_local_evidence_and_the_succeeded_status_alias() {
    let ledger: Ledger = serde_json::from_value(serde_json::json!({
        "format": "tron.worker_poc_observations.v1",
        "criteria": {
            "minimumSubstantiveScenarios": 1,
            "minimumDistinctDays": 1,
            "minimumAutonomousAdaptations": 1,
            "minimumProactiveAdaptations": 1,
            "prohibitedUnresolvedFailureCauses": ["authority_ceremony"]
        },
        "observations": [{
            "id": "real-proactive-adaptation",
            "completedAt": "2026-07-20T14:58:43Z",
            "summary": "A live session created and invoked a durable worker proactively.",
            "substantive": true,
            "autonomousAdaptation": true,
            "proactiveAdaptation": true,
            "status": "succeeded",
            "resolved": true,
            "evidence": ["session:real", "worker:real"],
            "notes": ["The user requested the task, not worker creation."]
        }]
    }))
    .expect("decode rich local ledger");

    assert!(gate_errors(&ledger).is_empty());
}

#[test]
#[ignore = "requires a local empirical ledger gathered across at least three days"]
fn worker_poc_empirical_gate() {
    let path = std::env::var("TRON_WORKER_POC_LEDGER")
        .expect("set TRON_WORKER_POC_LEDGER to an absolute local observation-ledger path");
    let path = Path::new(&path);
    assert!(
        path.is_absolute(),
        "TRON_WORKER_POC_LEDGER must be absolute"
    );
    let ledger = read_ledger(path);
    let errors = gate_errors(&ledger);
    assert!(
        errors.is_empty(),
        "worker POC gate remains open:\n{}",
        errors.join("\n")
    );
}
