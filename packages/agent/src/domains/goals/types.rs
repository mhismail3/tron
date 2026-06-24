use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const GOAL_SCHEMA_VERSION: &str = "tron.goals.goal.v1";
pub(super) const QUESTION_SCHEMA_VERSION: &str = "tron.goals.user_question.v1";
pub(super) const ANSWER_SCHEMA_VERSION: &str = "tron.goals.answer.v1";
pub(super) const GOAL_KIND: &str = "goal";
pub(super) const GOAL_SCHEMA_ID: &str = "tron.resource.goal.v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum GoalState {
    Open,
    Cancelled,
}

impl GoalState {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Cancelled => "cancelled",
        }
    }

    pub(super) fn is_terminal(&self) -> bool {
        matches!(self, Self::Cancelled)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum QuestionState {
    Pending,
    Answered,
    Expired,
    Cancelled,
}

impl QuestionState {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Answered => "answered",
            Self::Expired => "expired",
            Self::Cancelled => "cancelled",
        }
    }

    pub(super) fn is_terminal(&self) -> bool {
        !matches!(self, Self::Pending)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoalRecord {
    pub(super) schema_version: String,
    pub(super) state: GoalState,
    pub(super) intent: String,
    pub(super) objective: String,
    pub(super) owner: Value,
    pub(super) scope: Value,
    pub(super) success_criteria: Vec<String>,
    pub(super) constraints: Value,
    pub(super) queue_refs: Vec<Value>,
    pub(super) plan_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) created_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) cancellation: Option<GoalCancellationRecord>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GoalCancellationRecord {
    pub(super) reason: String,
    pub(super) cancelled_at: DateTime<Utc>,
    pub(super) actor_id: String,
    pub(super) idempotency: IdempotencyRecord,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct QuestionRecord {
    pub(super) schema_version: String,
    pub(super) state: QuestionState,
    pub(super) prompt: String,
    pub(super) requester: Value,
    pub(super) scope: Value,
    pub(super) goal_ref: Option<Value>,
    pub(super) options: Vec<String>,
    pub(super) allow_free_form: bool,
    pub(super) expires_at: Option<DateTime<Utc>>,
    pub(super) created_at: DateTime<Utc>,
    pub(super) answered_at: Option<DateTime<Utc>>,
    pub(super) cancelled_at: Option<DateTime<Utc>>,
    pub(super) answer: Option<QuestionAnswerSummary>,
    pub(super) queue_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct QuestionAnswerSummary {
    pub(super) answer_resource_id: String,
    pub(super) answer_version_id: String,
    pub(super) text_preview: String,
    pub(super) text_truncated: bool,
    pub(super) actor: Value,
    pub(super) reason: String,
    pub(super) idempotency: IdempotencyRecord,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AnswerRecord {
    pub(super) schema_version: String,
    pub(super) question_resource_id: String,
    pub(super) question_version_id: String,
    pub(super) goal_ref: Option<Value>,
    pub(super) answer_text: String,
    pub(super) answer_text_truncated: bool,
    pub(super) actor: Value,
    pub(super) reason: String,
    pub(super) authority: Value,
    pub(super) freshness: Value,
    pub(super) unblocks_goal: bool,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) idempotency: IdempotencyRecord,
    pub(super) answered_at: DateTime<Utc>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct IdempotencyRecord {
    pub(super) key: Option<String>,
    pub(super) invocation_id: String,
    pub(super) function_id: String,
}
