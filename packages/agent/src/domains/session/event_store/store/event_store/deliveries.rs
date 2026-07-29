//! Durable agent deliveries, result grants, mailboxes, and worker waits.
//!
//! Delivery content is reference context, never replay history or authority.
//! The EventStore owns every state transition so session lifecycle, mailbox
//! claims, wait resolution, and provider-turn leasing remain transactional.

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{OptionalExtension, Transaction, params, params_from_iter};
use serde::{Deserialize, Serialize};

use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::sqlite::repositories::event::EventRepo;
use crate::domains::session::event_store::sqlite::repositories::session::SessionRepo;
use crate::domains::session::event_store::sqlite::row_types::SessionRow;

use super::session_lifecycle::{CreateSessionInTxOptions, create_session_in_tx};
use super::{CreateSessionResult, EventStore};

pub(crate) const MAX_DELIVERIES_PER_TURN: usize = 8;
pub(crate) const MAX_DELIVERY_CONTENT_BYTES: usize = 40_000;
pub(crate) const MAX_MAILBOX_NAME_BYTES: usize = 64;
pub(crate) const MAX_WAIT_MEMBERS: usize = 32;
const MAX_IDEMPOTENCY_KEY_BYTES: usize = 256;
const MAX_ERROR_BYTES: usize = 1_024;
const MAX_AUTONOMOUS_CAUSAL_DEPTH: u32 = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentDeliverySourceKind {
    WorkerResult,
    AgentMessage,
    Continuity,
}

impl AgentDeliverySourceKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::WorkerResult => "worker_result",
            Self::AgentMessage => "agent_message",
            Self::Continuity => "continuity",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "worker_result" => Ok(Self::WorkerResult),
            "agent_message" => Ok(Self::AgentMessage),
            "continuity" => Ok(Self::Continuity),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent delivery source kind '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentDeliveryIntent {
    Information,
    Request,
}

impl AgentDeliveryIntent {
    fn as_str(self) -> &'static str {
        match self {
            Self::Information => "information",
            Self::Request => "request",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "information" => Ok(Self::Information),
            "request" => Ok(Self::Request),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent delivery intent '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentDeliveryWakePolicy {
    Passive,
    Wake,
}

impl AgentDeliveryWakePolicy {
    fn as_str(self) -> &'static str {
        match self {
            Self::Passive => "passive",
            Self::Wake => "wake",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "passive" => Ok(Self::Passive),
            "wake" => Ok(Self::Wake),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent delivery wake policy '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentDeliveryBoundary {
    NextTurn,
    NextRun,
}

impl AgentDeliveryBoundary {
    fn as_str(self) -> &'static str {
        match self {
            Self::NextTurn => "next_turn",
            Self::NextRun => "next_run",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "next_turn" => Ok(Self::NextTurn),
            "next_run" => Ok(Self::NextRun),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent delivery boundary '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentDeliveryDisposition {
    Pending,
    Observed,
    Cancelled,
    Stale,
}

impl AgentDeliveryDisposition {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "pending" => Ok(Self::Pending),
            "observed" => Ok(Self::Observed),
            "cancelled" => Ok(Self::Cancelled),
            "stale" => Ok(Self::Stale),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent delivery disposition '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentMailboxScope {
    Workspace,
    Profile,
}

impl AgentMailboxScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::Workspace => "workspace",
            Self::Profile => "profile",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "workspace" => Ok(Self::Workspace),
            "profile" => Ok(Self::Profile),
            other => Err(EventStoreError::InvalidOperation(format!(
                "unknown agent mailbox scope '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) enum AgentDeliveryTarget {
    Session {
        session_id: String,
    },
    Mailbox {
        scope: AgentMailboxScope,
        workspace_id: Option<String>,
        name: String,
    },
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentDelivery {
    pub(crate) idempotency_key: String,
    pub(crate) source_kind: AgentDeliverySourceKind,
    pub(crate) intent: Option<AgentDeliveryIntent>,
    pub(crate) source_session_id: Option<String>,
    pub(crate) source_workspace_id: String,
    pub(crate) source_invocation_id: Option<String>,
    pub(crate) source_trace_id: Option<String>,
    pub(crate) source_root_invocation_id: Option<String>,
    pub(crate) causal_depth: u32,
    pub(crate) target: AgentDeliveryTarget,
    pub(crate) wake_policy: AgentDeliveryWakePolicy,
    pub(crate) boundary: AgentDeliveryBoundary,
    pub(crate) originating_run_id: Option<String>,
    pub(crate) arrived_during_run_id: Option<String>,
    pub(crate) defer_until_run_id: Option<String>,
    pub(crate) result_invocation_id: Option<String>,
    pub(crate) content: String,
    pub(crate) not_before: Option<String>,
    pub(crate) expires_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentTaskDelivery {
    pub(crate) idempotency_key: String,
    pub(crate) source_session_id: String,
    pub(crate) title: String,
    pub(crate) model: Option<String>,
    pub(crate) working_directory: Option<String>,
    pub(crate) intent: AgentDeliveryIntent,
    pub(crate) wake_policy: AgentDeliveryWakePolicy,
    pub(crate) boundary: AgentDeliveryBoundary,
    pub(crate) content: String,
    pub(crate) expires_at: Option<String>,
    pub(crate) source_invocation_id: Option<String>,
    pub(crate) source_trace_id: Option<String>,
    pub(crate) source_root_invocation_id: Option<String>,
    pub(crate) causal_depth: u32,
}

#[derive(Debug)]
pub(crate) struct CreateAgentTaskResult {
    pub(crate) session: CreateSessionResult,
    pub(crate) delivery: AgentDeliveryRecord,
    pub(crate) created: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentDeliveryRecord {
    pub(crate) delivery_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) source_kind: AgentDeliverySourceKind,
    pub(crate) intent: Option<AgentDeliveryIntent>,
    pub(crate) source_session_id: Option<String>,
    pub(crate) source_workspace_id: String,
    pub(crate) source_invocation_id: Option<String>,
    pub(crate) source_trace_id: Option<String>,
    pub(crate) source_root_invocation_id: Option<String>,
    pub(crate) causal_depth: u32,
    pub(crate) target_session_id: Option<String>,
    pub(crate) mailbox_scope: Option<AgentMailboxScope>,
    pub(crate) mailbox_workspace_id: Option<String>,
    pub(crate) mailbox_name: Option<String>,
    pub(crate) wake_policy: AgentDeliveryWakePolicy,
    pub(crate) boundary: AgentDeliveryBoundary,
    pub(crate) originating_run_id: Option<String>,
    pub(crate) arrived_during_run_id: Option<String>,
    pub(crate) defer_until_run_id: Option<String>,
    pub(crate) result_invocation_id: Option<String>,
    pub(crate) content: String,
    pub(crate) not_before: Option<String>,
    pub(crate) expires_at: Option<String>,
    pub(crate) disposition: AgentDeliveryDisposition,
    pub(crate) leased_run_id: Option<String>,
    pub(crate) leased_turn: Option<u32>,
    pub(crate) lease_count: u32,
    pub(crate) wake_attempts: u32,
    pub(crate) next_wake_at: Option<String>,
    pub(crate) last_error: Option<String>,
    pub(crate) created_at: String,
    pub(crate) claimed_at: Option<String>,
    pub(crate) observed_at: Option<String>,
    pub(crate) cancelled_at: Option<String>,
}

impl AgentDeliveryRecord {
    pub(crate) fn is_redelivery(&self) -> bool {
        self.lease_count > 1
    }

    pub(crate) fn projection_status(&self) -> &'static str {
        match self.disposition {
            AgentDeliveryDisposition::Pending if self.leased_run_id.is_some() => "prepared",
            AgentDeliveryDisposition::Pending
                if self.wake_attempts >= 3
                    && self.wake_policy == AgentDeliveryWakePolicy::Passive
                    && self.last_error.is_some() =>
            {
                "retry_exhausted"
            }
            AgentDeliveryDisposition::Pending => "pending",
            AgentDeliveryDisposition::Observed => "observed",
            AgentDeliveryDisposition::Cancelled => "cancelled",
            AgentDeliveryDisposition::Stale => "stale",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentWaitMode {
    All,
    Any,
}

impl AgentWaitMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Any => "any",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentWait {
    pub(crate) idempotency_key: String,
    pub(crate) session_id: String,
    pub(crate) source_invocation_id: String,
    pub(crate) source_trace_id: String,
    pub(crate) source_root_invocation_id: Option<String>,
    pub(crate) causal_depth: u32,
    pub(crate) mode: AgentWaitMode,
    pub(crate) invocation_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentWaitRecord {
    pub(crate) wait_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) session_id: String,
    pub(crate) source_invocation_id: String,
    pub(crate) source_trace_id: String,
    pub(crate) source_root_invocation_id: Option<String>,
    pub(crate) causal_depth: u32,
    pub(crate) mode: AgentWaitMode,
    pub(crate) disposition: String,
    pub(crate) delivery_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) resolved_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct WorkerTerminalEvidence {
    pub(crate) invocation_id: String,
    pub(crate) status: String,
    pub(crate) evidence: String,
}

const DELIVERY_COLUMNS: &str = "
    delivery_id,idempotency_key,source_kind,intent,source_session_id,
    source_workspace_id,source_invocation_id,source_trace_id,
    source_root_invocation_id,causal_depth,target_session_id,mailbox_scope,
    mailbox_workspace_id,mailbox_name,wake_policy,boundary,
    originating_run_id,arrived_during_run_id,defer_until_run_id,
    result_invocation_id,content,not_before,expires_at,disposition,
    leased_run_id,leased_turn,lease_count,wake_attempts,next_wake_at,last_error,
    created_at,claimed_at,observed_at,cancelled_at
";

fn bounded_error(value: &str) -> String {
    value.chars().take(MAX_ERROR_BYTES).collect()
}

fn require_visible_session(session: SessionRow, role: &str) -> Result<SessionRow> {
    if session.is_worker_session() {
        return Err(EventStoreError::InvalidOperation(format!(
            "worker audit sessions cannot act as an agent delivery {role}"
        )));
    }
    Ok(session)
}

fn validate_delivery(delivery: &NewAgentDelivery) -> Result<()> {
    if delivery.idempotency_key.is_empty()
        || delivery.idempotency_key.len() > MAX_IDEMPOTENCY_KEY_BYTES
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "delivery idempotency key must contain 1..={MAX_IDEMPOTENCY_KEY_BYTES} UTF-8 bytes"
        )));
    }
    if delivery.source_workspace_id.trim().is_empty() {
        return Err(EventStoreError::InvalidOperation(
            "delivery source workspace must not be empty".to_owned(),
        ));
    }
    if delivery.content.trim().is_empty()
        || delivery.content.as_bytes().len() > MAX_DELIVERY_CONTENT_BYTES
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "delivery content must contain 1..={MAX_DELIVERY_CONTENT_BYTES} UTF-8 bytes"
        )));
    }
    for (field, value) in [
        ("not_before", delivery.not_before.as_deref()),
        ("expires_at", delivery.expires_at.as_deref()),
    ] {
        if let Some(value) = value {
            chrono::DateTime::parse_from_rfc3339(value).map_err(|_| {
                EventStoreError::InvalidOperation(format!(
                    "agent delivery {field} must be an RFC 3339 timestamp"
                ))
            })?;
        }
    }
    if matches!(delivery.source_kind, AgentDeliverySourceKind::AgentMessage)
        && delivery.intent.is_none()
    {
        return Err(EventStoreError::InvalidOperation(
            "agent messages require an information or request intent".to_owned(),
        ));
    }
    match &delivery.target {
        AgentDeliveryTarget::Session { session_id } if session_id.trim().is_empty() => {
            return Err(EventStoreError::InvalidOperation(
                "delivery target session must not be empty".to_owned(),
            ));
        }
        AgentDeliveryTarget::Mailbox {
            scope,
            workspace_id,
            name,
        } => {
            if name.trim().is_empty() || name.as_bytes().len() > MAX_MAILBOX_NAME_BYTES {
                return Err(EventStoreError::InvalidOperation(format!(
                    "mailbox name must contain 1..={MAX_MAILBOX_NAME_BYTES} UTF-8 bytes"
                )));
            }
            if matches!(scope, AgentMailboxScope::Workspace) && workspace_id.is_none() {
                return Err(EventStoreError::InvalidOperation(
                    "workspace mailbox requires a workspace id".to_owned(),
                ));
            }
            if matches!(scope, AgentMailboxScope::Profile) && workspace_id.is_some() {
                return Err(EventStoreError::InvalidOperation(
                    "profile mailbox must not carry a workspace id".to_owned(),
                ));
            }
        }
        AgentDeliveryTarget::Session { .. } => {}
    }
    Ok(())
}

pub(super) fn insert_delivery_in_tx(
    tx: &Transaction<'_>,
    delivery: &NewAgentDelivery,
) -> Result<AgentDeliveryRecord> {
    validate_delivery(delivery)?;
    if let Some(source_session_id) = delivery.source_session_id.as_deref() {
        let source = require_visible_session(
            SessionRepo::get_by_id(tx, source_session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(source_session_id.to_owned()))?,
            "source",
        )?;
        if source.workspace_id != delivery.source_workspace_id {
            return Err(EventStoreError::InvalidOperation(
                "agent delivery source session does not belong to its derived workspace".to_owned(),
            ));
        }
    }
    let (target_kind, target_session_id, mailbox_scope, mailbox_workspace_id, mailbox_name) =
        match &delivery.target {
            AgentDeliveryTarget::Session { session_id } => {
                let target = require_visible_session(
                    SessionRepo::get_by_id(tx, session_id)?
                        .ok_or_else(|| EventStoreError::SessionNotFound(session_id.clone()))?,
                    "target",
                )?;
                if target.workspace_id != delivery.source_workspace_id {
                    return Err(EventStoreError::InvalidOperation(
                        "agent deliveries may target only a session in the source workspace"
                            .to_owned(),
                    ));
                }
                ("session", Some(session_id.as_str()), None, None, None)
            }
            AgentDeliveryTarget::Mailbox {
                scope,
                workspace_id,
                name,
            } => {
                if matches!(scope, AgentMailboxScope::Workspace)
                    && workspace_id.as_deref() != Some(delivery.source_workspace_id.as_str())
                {
                    return Err(EventStoreError::InvalidOperation(
                        "workspace mailbox must match the source workspace".to_owned(),
                    ));
                }
                (
                    "mailbox",
                    None,
                    Some(scope.as_str()),
                    workspace_id.as_deref(),
                    Some(name.as_str()),
                )
            }
        };
    let delivery_id = format!("delivery_{}", uuid::Uuid::now_v7());
    let created_at = chrono::Utc::now().to_rfc3339();
    let effective_wake_policy = if delivery.causal_depth > MAX_AUTONOMOUS_CAUSAL_DEPTH {
        AgentDeliveryWakePolicy::Passive
    } else {
        delivery.wake_policy
    };
    tx.execute(
        "INSERT OR IGNORE INTO agent_deliveries(
            delivery_id,idempotency_key,source_kind,intent,source_session_id,
            source_workspace_id,source_invocation_id,source_trace_id,
            source_root_invocation_id,causal_depth,target_kind,target_session_id,
            mailbox_scope,mailbox_workspace_id,mailbox_name,wake_policy,boundary,
            originating_run_id,arrived_during_run_id,defer_until_run_id,
            result_invocation_id,content,not_before,expires_at,created_at
         ) VALUES (
            ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,
            ?18,?19,?20,?21,?22,?23,?24,?25
         )",
        params![
            delivery_id,
            delivery.idempotency_key,
            delivery.source_kind.as_str(),
            delivery.intent.map(AgentDeliveryIntent::as_str),
            delivery.source_session_id,
            delivery.source_workspace_id,
            delivery.source_invocation_id,
            delivery.source_trace_id,
            delivery.source_root_invocation_id,
            delivery.causal_depth,
            target_kind,
            target_session_id,
            mailbox_scope,
            mailbox_workspace_id,
            mailbox_name,
            effective_wake_policy.as_str(),
            delivery.boundary.as_str(),
            delivery.originating_run_id,
            delivery.arrived_during_run_id,
            delivery.defer_until_run_id,
            delivery.result_invocation_id,
            delivery.content,
            delivery.not_before,
            delivery.expires_at,
            created_at,
        ],
    )?;
    delivery_by_idempotency_key_in_tx(tx, &delivery.idempotency_key)?
        .ok_or_else(|| EventStoreError::Internal("inserted agent delivery disappeared".to_owned()))
}

fn delivery_by_idempotency_key_in_tx(
    tx: &Transaction<'_>,
    key: &str,
) -> Result<Option<AgentDeliveryRecord>> {
    tx.query_row(
        &format!("SELECT {DELIVERY_COLUMNS} FROM agent_deliveries WHERE idempotency_key=?1"),
        [key],
        map_delivery,
    )
    .optional()
    .map_err(EventStoreError::from)
}

fn map_delivery(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentDeliveryRecord> {
    let source_kind =
        AgentDeliverySourceKind::parse(&row.get::<_, String>(2)?).map_err(to_sql_decode_error)?;
    let intent = row
        .get::<_, Option<String>>(3)?
        .map(|value| AgentDeliveryIntent::parse(&value))
        .transpose()
        .map_err(to_sql_decode_error)?;
    let mailbox_scope = row
        .get::<_, Option<String>>(11)?
        .map(|value| AgentMailboxScope::parse(&value))
        .transpose()
        .map_err(to_sql_decode_error)?;
    let wake_policy =
        AgentDeliveryWakePolicy::parse(&row.get::<_, String>(14)?).map_err(to_sql_decode_error)?;
    let boundary =
        AgentDeliveryBoundary::parse(&row.get::<_, String>(15)?).map_err(to_sql_decode_error)?;
    let disposition =
        AgentDeliveryDisposition::parse(&row.get::<_, String>(23)?).map_err(to_sql_decode_error)?;
    Ok(AgentDeliveryRecord {
        delivery_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        source_kind,
        intent,
        source_session_id: row.get(4)?,
        source_workspace_id: row.get(5)?,
        source_invocation_id: row.get(6)?,
        source_trace_id: row.get(7)?,
        source_root_invocation_id: row.get(8)?,
        causal_depth: row.get(9)?,
        target_session_id: row.get(10)?,
        mailbox_scope,
        mailbox_workspace_id: row.get(12)?,
        mailbox_name: row.get(13)?,
        wake_policy,
        boundary,
        originating_run_id: row.get(16)?,
        arrived_during_run_id: row.get(17)?,
        defer_until_run_id: row.get(18)?,
        result_invocation_id: row.get(19)?,
        content: row.get(20)?,
        not_before: row.get(21)?,
        expires_at: row.get(22)?,
        disposition,
        leased_run_id: row.get(24)?,
        leased_turn: row.get(25)?,
        lease_count: row.get(26)?,
        wake_attempts: row.get(27)?,
        next_wake_at: row.get(28)?,
        last_error: row.get(29)?,
        created_at: row.get(30)?,
        claimed_at: row.get(31)?,
        observed_at: row.get(32)?,
        cancelled_at: row.get(33)?,
    })
}

fn to_sql_decode_error(error: EventStoreError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

impl EventStore {
    pub(crate) fn create_agent_task_with_delivery(
        &self,
        request: &NewAgentTaskDelivery,
    ) -> Result<CreateAgentTaskResult> {
        if request.title.trim().is_empty() || request.title.as_bytes().len() > 120 {
            return Err(EventStoreError::InvalidOperation(
                "agent-created task title must contain 1..=120 UTF-8 bytes".to_owned(),
            ));
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

            if let Some(delivery) =
                delivery_by_idempotency_key_in_tx(&transaction, &request.idempotency_key)?
            {
                let target_session_id = delivery.target_session_id.as_deref().ok_or_else(|| {
                    EventStoreError::InvalidOperation(
                        "agent task idempotency key belongs to a mailbox delivery".to_owned(),
                    )
                })?;
                let session =
                    SessionRepo::get_by_id(&transaction, target_session_id)?.ok_or_else(|| {
                        EventStoreError::SessionNotFound(target_session_id.to_owned())
                    })?;
                let root_event_id = session.root_event_id.as_deref().ok_or_else(|| {
                    EventStoreError::InvalidOperation(
                        "agent-created task has no root event".to_owned(),
                    )
                })?;
                let root_event = EventRepo::get_by_id(&transaction, root_event_id)?
                    .ok_or_else(|| EventStoreError::EventNotFound(root_event_id.to_owned()))?;
                transaction.commit()?;
                return Ok(CreateAgentTaskResult {
                    session: CreateSessionResult {
                        session,
                        root_event,
                    },
                    delivery,
                    created: false,
                });
            }

            let source = SessionRepo::get_by_id(&transaction, &request.source_session_id)?
                .ok_or_else(|| {
                    EventStoreError::SessionNotFound(request.source_session_id.clone())
                })?;
            if source.is_worker_session() {
                return Err(EventStoreError::InvalidOperation(
                    "worker audit sessions cannot create visible agent tasks".to_owned(),
                ));
            }
            let working_directory = request
                .working_directory
                .as_deref()
                .unwrap_or(&source.working_directory);
            if working_directory != source.working_directory {
                return Err(EventStoreError::InvalidOperation(
                    "agent-created tasks must remain in the source workspace".to_owned(),
                ));
            }
            let model = request.model.as_deref().unwrap_or(&source.latest_model);
            if model.trim().is_empty() {
                return Err(EventStoreError::InvalidOperation(
                    "agent-created task model must not be empty".to_owned(),
                ));
            }
            let session = create_session_in_tx(
                &transaction,
                &CreateSessionInTxOptions {
                    model,
                    workspace_path: working_directory,
                    title: Some(request.title.trim()),
                    provider: None,
                    tags: None,
                },
            )?;
            if session.session.workspace_id != source.workspace_id {
                return Err(EventStoreError::InvalidOperation(
                    "agent-created task resolved outside the source workspace".to_owned(),
                ));
            }
            let delivery = insert_delivery_in_tx(
                &transaction,
                &NewAgentDelivery {
                    idempotency_key: request.idempotency_key.clone(),
                    source_kind: AgentDeliverySourceKind::AgentMessage,
                    intent: Some(request.intent),
                    source_session_id: Some(source.id),
                    source_workspace_id: source.workspace_id,
                    source_invocation_id: request.source_invocation_id.clone(),
                    source_trace_id: request.source_trace_id.clone(),
                    source_root_invocation_id: request.source_root_invocation_id.clone(),
                    causal_depth: request.causal_depth,
                    target: AgentDeliveryTarget::Session {
                        session_id: session.session.id.clone(),
                    },
                    wake_policy: request.wake_policy,
                    boundary: request.boundary,
                    originating_run_id: None,
                    arrived_during_run_id: None,
                    defer_until_run_id: None,
                    result_invocation_id: None,
                    content: request.content.clone(),
                    not_before: None,
                    expires_at: request.expires_at.clone(),
                },
            )?;
            transaction.commit()?;
            Ok(CreateAgentTaskResult {
                session,
                delivery,
                created: true,
            })
        })
    }

    pub(crate) fn create_agent_delivery(
        &self,
        delivery: &NewAgentDelivery,
    ) -> Result<AgentDeliveryRecord> {
        let target_session = match &delivery.target {
            AgentDeliveryTarget::Session { session_id } => Some(session_id.clone()),
            AgentDeliveryTarget::Mailbox { .. } => None,
        };
        let write = || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let record = insert_delivery_in_tx(&transaction, delivery)?;
            transaction.commit()?;
            Ok(record)
        };
        if let Some(session_id) = target_session {
            self.with_session_write_lock(&session_id, write)
        } else {
            self.with_global_write_lock(write)
        }
    }

    #[cfg(test)]
    pub(crate) fn agent_delivery(&self, delivery_id: &str) -> Result<Option<AgentDeliveryRecord>> {
        let connection = self.conn()?;
        connection
            .query_row(
                &format!("SELECT {DELIVERY_COLUMNS} FROM agent_deliveries WHERE delivery_id=?1"),
                [delivery_id],
                map_delivery,
            )
            .optional()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn list_agent_deliveries_for_session(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentDeliveryRecord>> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let _ = SessionRepo::get_by_id(&connection, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
        let mut statement = connection.prepare(&format!(
            "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries
             WHERE target_session_id=?1
             ORDER BY created_at DESC,delivery_id DESC LIMIT ?2"
        ))?;
        statement
            .query_map(
                params![
                    session_id,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200)
                ],
                map_delivery,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn list_agent_waits_for_session(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentWaitRecord>> {
        let connection = self.conn()?;
        let _ = SessionRepo::get_by_id(&connection, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
        let mut statement = connection.prepare(
            "SELECT wait_id,idempotency_key,session_id,source_invocation_id,
                    source_trace_id,source_root_invocation_id,causal_depth,
                    mode,disposition,delivery_id,created_at,resolved_at
             FROM agent_waits WHERE session_id=?1
             ORDER BY created_at DESC,wait_id DESC LIMIT ?2",
        )?;
        statement
            .query_map(
                params![
                    session_id,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200)
                ],
                map_wait,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn lease_agent_deliveries(
        &self,
        session_id: &str,
        run_id: &str,
        turn: u32,
        only_ids: Option<&[String]>,
    ) -> Result<Vec<AgentDeliveryRecord>> {
        self.with_session_write_lock(session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agent_deliveries
                 SET disposition='cancelled',cancelled_at=?2,leased_run_id=NULL,leased_turn=NULL
                 WHERE target_session_id=?1 AND disposition='pending'
                   AND expires_at IS NOT NULL
                   AND rfc3339_sort_key(expires_at)<=rfc3339_sort_key(?2)",
                params![session_id, now],
            )?;

            let mut sql = format!(
                "SELECT delivery_id,length(CAST(content AS BLOB)) FROM agent_deliveries
                 WHERE target_session_id=?1 AND disposition='pending'
                   AND leased_run_id IS NULL
                   AND (not_before IS NULL OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?2))
                   AND (expires_at IS NULL OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?2))
                   AND (defer_until_run_id IS NULL OR defer_until_run_id<>?3)"
            );
            let candidates = if let Some(ids) = only_ids {
                if ids.is_empty() {
                    Vec::new()
                } else {
                    sql.push_str(&format!(
                        " AND delivery_id IN ({})",
                        std::iter::repeat_n("?", ids.len())
                            .enumerate()
                            .map(|(index, _)| format!("?{}", index + 4))
                            .collect::<Vec<_>>()
                            .join(",")
                    ));
                    sql.push_str(" ORDER BY created_at,delivery_id LIMIT 8");
                    let values =
                        std::iter::once(rusqlite::types::Value::Text(session_id.to_owned()))
                            .chain(std::iter::once(rusqlite::types::Value::Text(now.clone())))
                            .chain(std::iter::once(rusqlite::types::Value::Text(
                                run_id.to_owned(),
                            )))
                            .chain(ids.iter().cloned().map(rusqlite::types::Value::Text))
                            .collect::<Vec<_>>();
                    transaction
                        .prepare(&sql)?
                        .query_map(params_from_iter(values), |row| {
                            Ok((row.get::<_, String>(0)?, row.get::<_, usize>(1)?))
                        })?
                        .collect::<rusqlite::Result<Vec<_>>>()?
                }
            } else {
                sql.push_str(" ORDER BY created_at,delivery_id LIMIT 8");
                transaction
                    .prepare(&sql)?
                    .query_map(params![session_id, now, run_id], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, usize>(1)?))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            let mut aggregate_bytes = 0_usize;
            let selected = candidates
                .into_iter()
                .take_while(|(_, content_bytes)| {
                    let next = aggregate_bytes.saturating_add(*content_bytes);
                    if next > MAX_DELIVERY_CONTENT_BYTES {
                        return false;
                    }
                    aggregate_bytes = next;
                    true
                })
                .map(|(delivery_id, _)| delivery_id)
                .collect::<Vec<_>>();
            for delivery_id in &selected {
                transaction.execute(
                    "UPDATE agent_deliveries
                     SET leased_run_id=?2,leased_turn=?3,lease_count=lease_count+1
                     WHERE delivery_id=?1 AND disposition='pending' AND leased_run_id IS NULL",
                    params![delivery_id, run_id, turn],
                )?;
            }
            let mut records = Vec::with_capacity(selected.len());
            for delivery_id in selected {
                let record = transaction.query_row(
                    &format!(
                        "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries WHERE delivery_id=?1"
                    ),
                    [delivery_id],
                    map_delivery,
                )?;
                records.push(record);
            }
            transaction.commit()?;
            Ok(records)
        })
    }

    pub(crate) fn observe_agent_deliveries(
        &self,
        session_id: &str,
        run_id: &str,
        turn: u32,
    ) -> Result<usize> {
        self.with_session_write_lock(session_id, || {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            connection
                .execute(
                    "UPDATE agent_deliveries
                     SET disposition='observed',observed_at=?4,
                         leased_run_id=NULL,leased_turn=NULL
                     WHERE target_session_id=?1 AND disposition='pending'
                       AND leased_run_id=?2 AND leased_turn=?3",
                    params![session_id, run_id, turn, now],
                )
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn release_agent_delivery_leases(&self, run_id: &str) -> Result<usize> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            connection
                .execute(
                    "UPDATE agent_deliveries SET leased_run_id=NULL,leased_turn=NULL
                     WHERE disposition='pending' AND leased_run_id=?1",
                    [run_id],
                )
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn clear_agent_delivery_leases(&self) -> Result<usize> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            connection
                .execute(
                    "UPDATE agent_deliveries SET leased_run_id=NULL,leased_turn=NULL
                     WHERE disposition='pending' AND leased_run_id IS NOT NULL",
                    [],
                )
                .map_err(EventStoreError::from)
        })
    }

    /// Reconcile sender-selected expiry into durable cancellation.
    ///
    /// Reads also invoke this boundary so an expired mailbox row or result
    /// grant cannot remain logically live merely because no provider turn has
    /// attempted to lease it.
    pub(crate) fn expire_agent_deliveries(&self) -> Result<usize> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            connection
                .execute(
                    "UPDATE agent_deliveries
                     SET disposition='cancelled',cancelled_at=?1,
                         wake_policy='passive',next_wake_at=NULL,
                         leased_run_id=NULL,leased_turn=NULL
                     WHERE disposition='pending' AND expires_at IS NOT NULL
                       AND rfc3339_sort_key(expires_at)<=rfc3339_sort_key(?1)",
                    [now],
                )
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn pending_agent_wakes(
        &self,
        limit: usize,
    ) -> Result<BTreeMap<String, Vec<String>>> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut statement = connection.prepare(
            "SELECT delivery.delivery_id,delivery.target_session_id
             FROM agent_deliveries delivery
             JOIN sessions session ON session.id=delivery.target_session_id
             WHERE delivery.disposition='pending'
               AND delivery.wake_policy='wake'
               AND delivery.leased_run_id IS NULL
               AND session.ended_at IS NULL
               AND (delivery.not_before IS NULL
                    OR rfc3339_sort_key(delivery.not_before)<=rfc3339_sort_key(?1))
               AND (delivery.next_wake_at IS NULL
                    OR rfc3339_sort_key(delivery.next_wake_at)<=rfc3339_sort_key(?1))
               AND (delivery.expires_at IS NULL
                    OR rfc3339_sort_key(delivery.expires_at)>rfc3339_sort_key(?1))
             ORDER BY delivery.created_at,delivery.delivery_id
             LIMIT ?2",
        )?;
        let rows = statement
            .query_map(
                params![now, i64::try_from(limit).unwrap_or(i64::MAX)],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut grouped = BTreeMap::<String, Vec<String>>::new();
        for (delivery_id, session_id) in rows {
            grouped.entry(session_id).or_default().push(delivery_id);
        }
        Ok(grouped)
    }

    pub(crate) fn pending_agent_wakes_for_session(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<String>> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut statement = connection.prepare(
            "SELECT delivery.delivery_id
             FROM agent_deliveries delivery
             JOIN sessions session ON session.id=delivery.target_session_id
             WHERE delivery.target_session_id=?1
               AND delivery.disposition='pending'
               AND delivery.wake_policy='wake'
               AND delivery.leased_run_id IS NULL
               AND session.ended_at IS NULL
               AND (delivery.not_before IS NULL
                    OR rfc3339_sort_key(delivery.not_before)<=rfc3339_sort_key(?2))
               AND (delivery.next_wake_at IS NULL
                    OR rfc3339_sort_key(delivery.next_wake_at)<=rfc3339_sort_key(?2))
               AND (delivery.expires_at IS NULL
                    OR rfc3339_sort_key(delivery.expires_at)>rfc3339_sort_key(?2))
             ORDER BY delivery.created_at,delivery.delivery_id
             LIMIT ?3",
        )?;
        statement
            .query_map(
                params![
                    session_id,
                    now,
                    i64::try_from(limit.min(MAX_DELIVERIES_PER_TURN)).unwrap_or(8)
                ],
                |row| row.get::<_, String>(0),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn record_agent_wake_failure(
        &self,
        session_id: &str,
        delivery_ids: &[String],
        error: &str,
    ) -> Result<bool> {
        if delivery_ids.is_empty() {
            return Ok(false);
        }
        self.with_session_write_lock(session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let sanitized = bounded_error(error);
            let now = chrono::Utc::now();
            let mut demoted = false;
            let mut recorded = 0_u64;
            for delivery_id in delivery_ids {
                let attempts = transaction
                    .query_row(
                        "SELECT wake_attempts FROM agent_deliveries
                         WHERE delivery_id=?1 AND target_session_id=?2
                           AND disposition='pending' AND wake_policy='wake'",
                        params![delivery_id, session_id],
                        |row| row.get::<_, u32>(0),
                    )
                    .optional()?;
                let Some(attempts) = attempts else {
                    continue;
                };
                recorded = recorded.saturating_add(1);
                let next_attempt = attempts.saturating_add(1);
                if next_attempt >= 3 {
                    transaction.execute(
                        "UPDATE agent_deliveries
                         SET wake_attempts=?3,wake_policy='passive',next_wake_at=NULL,
                             last_error=?4,leased_run_id=NULL,leased_turn=NULL
                         WHERE delivery_id=?1 AND target_session_id=?2",
                        params![delivery_id, session_id, next_attempt, sanitized],
                    )?;
                    demoted = true;
                } else {
                    let delay_seconds = if next_attempt == 1 { 1 } else { 5 };
                    let next_wake = (now + chrono::Duration::seconds(delay_seconds)).to_rfc3339();
                    transaction.execute(
                        "UPDATE agent_deliveries
                         SET wake_attempts=?3,next_wake_at=?4,last_error=?5,
                             leased_run_id=NULL,leased_turn=NULL
                         WHERE delivery_id=?1 AND target_session_id=?2",
                        params![delivery_id, session_id, next_attempt, next_wake, sanitized],
                    )?;
                }
            }
            transaction.commit()?;
            if recorded > 0 {
                metrics::counter!(
                    "agent_delivery_wake_failures_total",
                    "outcome" => if demoted { "demoted" } else { "retry" }
                )
                .increment(recorded);
            }
            Ok(demoted)
        })
    }

    pub(crate) fn demote_agent_wakes(
        &self,
        session_id: &str,
        delivery_ids: &[String],
    ) -> Result<usize> {
        if delivery_ids.is_empty() {
            return Ok(0);
        }
        self.with_session_write_lock(session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let mut changed = 0_usize;
            for delivery_id in delivery_ids {
                changed = changed.saturating_add(transaction.execute(
                    "UPDATE agent_deliveries
                     SET wake_policy='passive',next_wake_at=NULL,
                         leased_run_id=NULL,leased_turn=NULL
                     WHERE delivery_id=?1 AND target_session_id=?2
                       AND disposition='pending' AND wake_policy='wake'",
                    params![delivery_id, session_id],
                )?);
            }
            transaction.commit()?;
            Ok(changed)
        })
    }

    pub(crate) fn demote_leased_agent_wakes(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Result<usize> {
        self.with_session_write_lock(session_id, || {
            let connection = self.conn()?;
            connection
                .execute(
                    "UPDATE agent_deliveries
                     SET wake_policy='passive',next_wake_at=NULL
                     WHERE target_session_id=?1 AND leased_run_id=?2
                       AND disposition='pending' AND wake_policy='wake'",
                    params![session_id, run_id],
                )
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn retry_exhausted_agent_deliveries(
        &self,
        limit: usize,
    ) -> Result<Vec<(String, String, String)>> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let mut statement = connection.prepare(
            "SELECT delivery_id,target_session_id,last_error
             FROM agent_deliveries
             WHERE disposition='pending' AND wake_policy='passive'
               AND wake_attempts>=3 AND last_error IS NOT NULL
               AND target_session_id IS NOT NULL
             ORDER BY created_at,delivery_id LIMIT ?1",
        )?;
        statement
            .query_map([i64::try_from(limit.clamp(1, 256)).unwrap_or(256)], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn stale_run_scoped_deliveries(
        &self,
        source_kind: AgentDeliverySourceKind,
        originating_run_id: &str,
    ) -> Result<usize> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            connection
                .execute(
                    "UPDATE agent_deliveries
                     SET disposition='stale',leased_run_id=NULL,leased_turn=NULL
                     WHERE source_kind=?1 AND originating_run_id=?2
                       AND disposition='pending'",
                    params![source_kind.as_str(), originating_run_id],
                )
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn list_agent_mailbox(
        &self,
        session_id: &str,
        scope: AgentMailboxScope,
        name: &str,
        limit: usize,
    ) -> Result<Vec<AgentDeliveryRecord>> {
        self.expire_agent_deliveries()?;
        if name.trim().is_empty() || name.as_bytes().len() > MAX_MAILBOX_NAME_BYTES {
            return Err(EventStoreError::InvalidOperation(
                "invalid mailbox name".to_owned(),
            ));
        }
        let connection = self.conn()?;
        let session = require_visible_session(
            SessionRepo::get_by_id(&connection, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?,
            "mailbox reader",
        )?;
        let now = chrono::Utc::now().to_rfc3339();
        let workspace_id =
            matches!(scope, AgentMailboxScope::Workspace).then_some(session.workspace_id.as_str());
        let mut statement = connection.prepare(&format!(
            "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries
             WHERE target_kind='mailbox' AND mailbox_scope=?1 AND mailbox_name=?2
               AND ((?3 IS NULL AND mailbox_workspace_id IS NULL)
                    OR mailbox_workspace_id=?3)
               AND disposition='pending'
               AND (not_before IS NULL OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?4))
               AND (expires_at IS NULL OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?4))
             ORDER BY created_at,delivery_id LIMIT ?5"
        ))?;
        statement
            .query_map(
                params![
                    scope.as_str(),
                    name,
                    workspace_id,
                    now,
                    i64::try_from(limit.min(100)).unwrap_or(100)
                ],
                map_delivery,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn list_agent_mailbox_candidates(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentDeliveryRecord>> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let session = require_visible_session(
            SessionRepo::get_by_id(&connection, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?,
            "mailbox reader",
        )?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut statement = connection.prepare(&format!(
            "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries
             WHERE target_kind='mailbox' AND disposition='pending'
               AND (
                    (mailbox_scope='workspace' AND mailbox_workspace_id=?1)
                    OR (mailbox_scope='profile' AND mailbox_workspace_id IS NULL)
               )
               AND (not_before IS NULL OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?2))
               AND (expires_at IS NULL OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?2))
             ORDER BY created_at,delivery_id LIMIT ?3"
        ))?;
        statement
            .query_map(
                params![
                    session.workspace_id,
                    now,
                    i64::try_from(limit.clamp(1, 100)).unwrap_or(100)
                ],
                map_delivery,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn claim_agent_mailbox(
        &self,
        session_id: &str,
        delivery_ids: &[String],
    ) -> Result<Vec<AgentDeliveryRecord>> {
        self.expire_agent_deliveries()?;
        if delivery_ids.is_empty() || delivery_ids.len() > MAX_DELIVERIES_PER_TURN {
            return Err(EventStoreError::InvalidOperation(format!(
                "mailbox claim requires 1..={MAX_DELIVERIES_PER_TURN} delivery ids"
            )));
        }
        if delivery_ids.iter().collect::<BTreeSet<_>>().len() != delivery_ids.len() {
            return Err(EventStoreError::InvalidOperation(
                "mailbox claim contains duplicate delivery ids".to_owned(),
            ));
        }
        // Mailbox ownership is profile/workspace-global. Two different target
        // sessions may race for the same row, so a target-session lock cannot
        // serialize the claim boundary.
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let session = require_visible_session(
                SessionRepo::get_by_id(&transaction, session_id)?
                    .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?,
                "mailbox claimant",
            )?;
            let now = chrono::Utc::now().to_rfc3339();
            let mut records = Vec::with_capacity(delivery_ids.len());
            for delivery_id in delivery_ids {
                let record = transaction
                    .query_row(
                        &format!(
                            "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries
                             WHERE delivery_id=?1 AND target_kind='mailbox'
                               AND disposition='pending'
                               AND (not_before IS NULL
                                    OR rfc3339_sort_key(not_before)<=rfc3339_sort_key(?2))
                               AND (expires_at IS NULL
                                    OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?2))"
                        ),
                        params![delivery_id, now],
                        map_delivery,
                    )
                    .optional()?
                    .ok_or_else(|| {
                        EventStoreError::InvalidOperation(format!(
                            "mailbox delivery '{delivery_id}' is unavailable"
                        ))
                    })?;
                if matches!(record.mailbox_scope, Some(AgentMailboxScope::Workspace))
                    && record.mailbox_workspace_id.as_deref() != Some(session.workspace_id.as_str())
                {
                    return Err(EventStoreError::InvalidOperation(format!(
                        "mailbox delivery '{delivery_id}' belongs to another workspace"
                    )));
                }
                records.push(record);
            }
            for delivery_id in delivery_ids {
                let changed = transaction.execute(
                    "UPDATE agent_deliveries
                     SET target_kind='session',target_session_id=?2,
                         mailbox_scope=NULL,mailbox_workspace_id=NULL,mailbox_name=NULL,
                         wake_policy='passive',boundary='next_turn',claimed_at=?3
                     WHERE delivery_id=?1 AND target_kind='mailbox'
                       AND disposition='pending'",
                    params![delivery_id, session_id, now],
                )?;
                if changed != 1 {
                    return Err(EventStoreError::InvalidOperation(
                        "mailbox claim lost a concurrent race".to_owned(),
                    ));
                }
            }
            transaction.commit()?;
            self.agent_deliveries_by_ids(delivery_ids)
        })
    }

    pub(crate) fn agent_deliveries_by_ids(
        &self,
        delivery_ids: &[String],
    ) -> Result<Vec<AgentDeliveryRecord>> {
        let connection = self.conn()?;
        let mut records = Vec::with_capacity(delivery_ids.len());
        for delivery_id in delivery_ids {
            let record = connection
                .query_row(
                    &format!(
                        "SELECT {DELIVERY_COLUMNS} FROM agent_deliveries WHERE delivery_id=?1"
                    ),
                    [delivery_id],
                    map_delivery,
                )
                .optional()?
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent delivery '{delivery_id}' was not found"
                    ))
                })?;
            records.push(record);
        }
        Ok(records)
    }

    pub(crate) fn session_has_agent_result_grant(
        &self,
        session_id: &str,
        invocation_id: &str,
    ) -> Result<bool> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let now = chrono::Utc::now().to_rfc3339();
        let found = connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM agent_deliveries
                WHERE target_session_id=?1 AND result_invocation_id=?2
                  AND disposition IN ('pending','observed')
                  AND (expires_at IS NULL
                       OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?3))
            )",
            params![session_id, invocation_id, now],
            |row| row.get::<_, bool>(0),
        )?;
        Ok(found)
    }

    pub(crate) fn has_agent_result_grant(&self, invocation_id: &str) -> Result<bool> {
        self.expire_agent_deliveries()?;
        let connection = self.conn()?;
        let now = chrono::Utc::now().to_rfc3339();
        connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM agent_deliveries
                    WHERE result_invocation_id=?1
                      AND disposition IN ('pending','observed')
                      AND (expires_at IS NULL
                           OR rfc3339_sort_key(expires_at)>rfc3339_sort_key(?2))
                )",
                params![invocation_id, now],
                |row| row.get::<_, bool>(0),
            )
            .map_err(EventStoreError::from)
    }

    pub(crate) fn create_agent_wait(&self, request: &NewAgentWait) -> Result<AgentWaitRecord> {
        if request.idempotency_key.is_empty()
            || request.idempotency_key.len() > MAX_IDEMPOTENCY_KEY_BYTES
        {
            return Err(EventStoreError::InvalidOperation(
                "invalid wait idempotency key".to_owned(),
            ));
        }
        if request.invocation_ids.is_empty() || request.invocation_ids.len() > MAX_WAIT_MEMBERS {
            return Err(EventStoreError::InvalidOperation(format!(
                "agent wait requires 1..={MAX_WAIT_MEMBERS} invocations"
            )));
        }
        if request.invocation_ids.iter().collect::<BTreeSet<_>>().len()
            != request.invocation_ids.len()
        {
            return Err(EventStoreError::InvalidOperation(
                "agent wait contains duplicate invocations".to_owned(),
            ));
        }
        self.with_session_write_lock(&request.session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let _ = require_visible_session(
                SessionRepo::get_by_id(&transaction, &request.session_id)?
                    .ok_or_else(|| EventStoreError::SessionNotFound(request.session_id.clone()))?,
                "wait owner",
            )?;
            let wait_id = format!("wait_{}", uuid::Uuid::now_v7());
            let created_at = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "INSERT OR IGNORE INTO agent_waits(
                    wait_id,idempotency_key,session_id,source_invocation_id,
                    source_trace_id,source_root_invocation_id,causal_depth,mode,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                params![
                    wait_id,
                    request.idempotency_key,
                    request.session_id,
                    request.source_invocation_id,
                    request.source_trace_id,
                    request.source_root_invocation_id,
                    request.causal_depth,
                    request.mode.as_str(),
                    created_at
                ],
            )?;
            let record = transaction.query_row(
                "SELECT wait_id,idempotency_key,session_id,source_invocation_id,
                        source_trace_id,source_root_invocation_id,causal_depth,
                        mode,disposition,delivery_id,created_at,resolved_at
                 FROM agent_waits WHERE idempotency_key=?1",
                [&request.idempotency_key],
                map_wait,
            )?;
            if record.disposition == "pending" {
                let member_count = transaction.query_row(
                    "SELECT COUNT(*) FROM agent_wait_members WHERE wait_id=?1",
                    [&record.wait_id],
                    |row| row.get::<_, usize>(0),
                )?;
                if member_count == 0 {
                    for (ordinal, invocation_id) in request.invocation_ids.iter().enumerate() {
                        transaction.execute(
                            "INSERT INTO agent_wait_members(
                                wait_id,invocation_id,ordinal
                             ) VALUES (?1,?2,?3)",
                            params![record.wait_id, invocation_id, ordinal],
                        )?;
                    }
                }
            }
            transaction.commit()?;
            Ok(record)
        })
    }

    pub(crate) fn pending_wait_invocation_ids(&self) -> Result<Vec<String>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(
            "SELECT DISTINCT member.invocation_id
             FROM agent_wait_members member
             JOIN agent_waits wait USING(wait_id)
             WHERE wait.disposition='pending' AND member.disposition='pending'
             ORDER BY member.invocation_id",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn reconcile_agent_waits(
        &self,
        terminals: &[WorkerTerminalEvidence],
    ) -> Result<Vec<AgentDeliveryRecord>> {
        if terminals.is_empty() {
            return Ok(Vec::new());
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            for terminal in terminals {
                transaction.execute(
                    "UPDATE agent_wait_members
                     SET disposition='satisfied',terminal_status=?2,
                         terminal_evidence=?3,resolved_at=?4
                     WHERE invocation_id=?1 AND disposition='pending'
                       AND wait_id IN (
                         SELECT wait_id FROM agent_waits WHERE disposition='pending'
                       )",
                    params![
                        terminal.invocation_id,
                        terminal.status,
                        terminal.evidence,
                        now
                    ],
                )?;
            }
            let waits = {
                let mut statement = transaction.prepare(
                    "SELECT wait_id,idempotency_key,session_id,source_invocation_id,
                            source_trace_id,source_root_invocation_id,causal_depth,
                            mode,disposition,delivery_id,created_at,resolved_at
                     FROM agent_waits WHERE disposition='pending' ORDER BY created_at,wait_id",
                )?;
                statement
                    .query_map([], map_wait)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            let mut deliveries = Vec::new();
            for wait in waits {
                let (pending, satisfied): (usize, usize) = transaction.query_row(
                    "SELECT
                        SUM(CASE WHEN disposition='pending' THEN 1 ELSE 0 END),
                        SUM(CASE WHEN disposition='satisfied' THEN 1 ELSE 0 END)
                     FROM agent_wait_members WHERE wait_id=?1",
                    [&wait.wait_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )?;
                let ready = match wait.mode {
                    AgentWaitMode::All => pending == 0,
                    AgentWaitMode::Any => satisfied > 0,
                };
                if !ready {
                    continue;
                }
                if matches!(wait.mode, AgentWaitMode::Any) {
                    transaction.execute(
                        "UPDATE agent_wait_members
                         SET disposition='ignored',resolved_at=?2
                         WHERE wait_id=?1 AND disposition='pending'",
                        params![wait.wait_id, now],
                    )?;
                }
                let evidence = {
                    let mut statement = transaction.prepare(
                        "SELECT invocation_id,terminal_status,terminal_evidence
                         FROM agent_wait_members
                         WHERE wait_id=?1 AND disposition='satisfied'
                         ORDER BY ordinal",
                    )?;
                    statement
                        .query_map([&wait.wait_id], |row| {
                            Ok(serde_json::json!({
                                "invocationId":row.get::<_, String>(0)?,
                                "status":row.get::<_, String>(1)?,
                                "evidence":row.get::<_, String>(2)?,
                            }))
                        })?
                        .collect::<rusqlite::Result<Vec<_>>>()?
                };
                let session = SessionRepo::get_by_id(&transaction, &wait.session_id)?
                    .ok_or_else(|| EventStoreError::SessionNotFound(wait.session_id.clone()))?;
                let content = serde_json::to_string(&serde_json::json!({
                    "kind":"worker_wait",
                    "waitId":wait.wait_id,
                    "mode":wait.mode.as_str(),
                    "results":evidence,
                }))?;
                let delivery = insert_delivery_in_tx(
                    &transaction,
                    &NewAgentDelivery {
                        idempotency_key: format!("wait-satisfied:{}", wait.wait_id),
                        source_kind: AgentDeliverySourceKind::WorkerResult,
                        intent: Some(AgentDeliveryIntent::Information),
                        source_session_id: Some(wait.session_id.clone()),
                        source_workspace_id: session.workspace_id,
                        source_invocation_id: Some(wait.source_invocation_id.clone()),
                        source_trace_id: Some(wait.source_trace_id.clone()),
                        source_root_invocation_id: wait.source_root_invocation_id.clone(),
                        causal_depth: wait.causal_depth,
                        target: AgentDeliveryTarget::Session {
                            session_id: wait.session_id.clone(),
                        },
                        wake_policy: AgentDeliveryWakePolicy::Wake,
                        boundary: AgentDeliveryBoundary::NextTurn,
                        originating_run_id: None,
                        arrived_during_run_id: None,
                        defer_until_run_id: None,
                        result_invocation_id: None,
                        content,
                        not_before: None,
                        expires_at: None,
                    },
                )?;
                transaction.execute(
                    "UPDATE agent_waits
                     SET disposition='satisfied',delivery_id=?2,resolved_at=?3
                     WHERE wait_id=?1 AND disposition='pending'",
                    params![wait.wait_id, delivery.delivery_id, now],
                )?;
                deliveries.push(delivery);
            }
            transaction.commit()?;
            Ok(deliveries)
        })
    }
}

fn map_wait(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentWaitRecord> {
    let mode = match row.get::<_, String>(7)?.as_str() {
        "all" => AgentWaitMode::All,
        "any" => AgentWaitMode::Any,
        other => {
            return Err(rusqlite::Error::FromSqlConversionFailure(
                3,
                rusqlite::types::Type::Text,
                format!("unknown agent wait mode '{other}'").into(),
            ));
        }
    };
    Ok(AgentWaitRecord {
        wait_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        session_id: row.get(2)?,
        source_invocation_id: row.get(3)?,
        source_trace_id: row.get(4)?,
        source_root_invocation_id: row.get(5)?,
        causal_depth: row.get(6)?,
        mode,
        disposition: row.get(8)?,
        delivery_id: row.get(9)?,
        created_at: row.get(10)?,
        resolved_at: row.get(11)?,
    })
}
