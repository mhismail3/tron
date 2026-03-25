//! Checkpoint and progress event payloads for durable execution.

use serde::{Deserialize, Serialize};

/// Maximum chars for pending_work and total completed_steps text.
const MAX_CHECKPOINT_FIELD_CHARS: usize = 2000;

/// Payload for `checkpoint.saved` events.
///
/// Emitted after significant turns to enable resumption from the last
/// checkpoint if the session is interrupted.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckpointSavedPayload {
    /// Turn number at which this checkpoint was taken.
    pub turn_number: u64,
    /// Summary of work remaining.
    pub pending_work: String,
    /// Steps completed so far.
    pub completed_steps: Vec<String>,
    /// Hash of the current context for staleness detection.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_hash: Option<String>,
}

impl CheckpointSavedPayload {
    /// Create a checkpoint payload with automatic truncation of large fields.
    pub fn new(
        turn_number: u64,
        pending_work: String,
        completed_steps: Vec<String>,
        context_hash: Option<String>,
    ) -> Self {
        let pending_work = if pending_work.len() > MAX_CHECKPOINT_FIELD_CHARS {
            format!("{}...[truncated]", &pending_work[..MAX_CHECKPOINT_FIELD_CHARS])
        } else {
            pending_work
        };

        // Truncate completed_steps to fit within budget
        let mut total_len = 0;
        let completed_steps: Vec<String> = completed_steps
            .into_iter()
            .take_while(|s| {
                total_len += s.len();
                total_len <= MAX_CHECKPOINT_FIELD_CHARS
            })
            .collect();

        Self {
            turn_number,
            pending_work,
            completed_steps,
            context_hash,
        }
    }
}

/// Payload for `progress.update` events.
///
/// Emitted during long-running tasks to communicate progress to the
/// iOS app (for progress bar display) and for audit purposes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressUpdatePayload {
    /// Current step description.
    pub step: String,
    /// Current step index (1-based).
    pub current: u64,
    /// Total number of steps (0 if unknown).
    pub total: u64,
    /// Detailed status message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn checkpoint_serde_roundtrip() {
        let payload = CheckpointSavedPayload {
            turn_number: 15,
            pending_work: "Run tests on modules B and C".into(),
            completed_steps: vec![
                "Refactored module A".into(),
                "Updated tests for A".into(),
            ],
            context_hash: Some("sha256-abc123".into()),
        };
        let json = serde_json::to_value(&payload).unwrap();
        assert_eq!(json["turnNumber"], 15);
        assert_eq!(json["pendingWork"], "Run tests on modules B and C");
        assert_eq!(json["completedSteps"].as_array().unwrap().len(), 2);
        assert_eq!(json["contextHash"], "sha256-abc123");

        let back: CheckpointSavedPayload = serde_json::from_value(json).unwrap();
        assert_eq!(back, payload);
    }

    #[test]
    fn checkpoint_without_hash() {
        let payload = CheckpointSavedPayload {
            turn_number: 5,
            pending_work: "finish".into(),
            completed_steps: vec![],
            context_hash: None,
        };
        let json = serde_json::to_value(&payload).unwrap();
        assert!(json.get("contextHash").is_none());
    }

    #[test]
    fn progress_serde_roundtrip() {
        let payload = ProgressUpdatePayload {
            step: "Running tests".into(),
            current: 3,
            total: 10,
            detail: Some("Module C".into()),
        };
        let json = serde_json::to_value(&payload).unwrap();
        assert_eq!(json["step"], "Running tests");
        assert_eq!(json["current"], 3);
        assert_eq!(json["total"], 10);
        assert_eq!(json["detail"], "Module C");

        let back: ProgressUpdatePayload = serde_json::from_value(json).unwrap();
        assert_eq!(back, payload);
    }

    #[test]
    fn progress_without_detail() {
        let payload = ProgressUpdatePayload {
            step: "Building".into(),
            current: 1,
            total: 0,
            detail: None,
        };
        let json = serde_json::to_value(&payload).unwrap();
        assert!(json.get("detail").is_none());
    }

    #[test]
    fn checkpoint_truncation_for_large_data() {
        let long_work = "x".repeat(5000);
        let payload = CheckpointSavedPayload::new(
            1,
            long_work,
            vec!["step".into()],
            None,
        );
        // pending_work should be truncated to ~2000 + "[truncated]"
        assert!(payload.pending_work.len() <= 2020);
        assert!(payload.pending_work.contains("[truncated]"));
    }

    #[test]
    fn checkpoint_truncation_completed_steps() {
        let many_steps: Vec<String> = (0..100)
            .map(|i| format!("Step {i}: did something with a very long description that takes up space"))
            .collect();
        let payload = CheckpointSavedPayload::new(1, "work".into(), many_steps, None);
        let total: usize = payload.completed_steps.iter().map(|s| s.len()).sum();
        assert!(total <= 2100, "total step chars should be bounded");
    }

    #[test]
    fn checkpoint_new_preserves_short_data() {
        let payload = CheckpointSavedPayload::new(
            5,
            "finish tests".into(),
            vec!["wrote module A".into()],
            Some("hash123".into()),
        );
        assert_eq!(payload.pending_work, "finish tests");
        assert_eq!(payload.completed_steps, vec!["wrote module A"]);
    }

    #[test]
    fn progress_from_json() {
        let json = json!({
            "step": "Deploying",
            "current": 5,
            "total": 5,
        });
        let payload: ProgressUpdatePayload = serde_json::from_value(json).unwrap();
        assert_eq!(payload.step, "Deploying");
        assert_eq!(payload.current, 5);
        assert!(payload.detail.is_none());
    }
}
