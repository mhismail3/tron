//! Semantic agent messages and generalized durable coordination waits.
//!
//! A canonical pending message stores bounded semantic content before the
//! recipient reaches a provider-safe boundary; materialization then appends the
//! same content to `message.agent` exactly once. This module also owns
//! engine-authored provenance, channel order, reply linkage, and observation
//! state. Accepted assignment messages are paired with a one-way durable
//! delivery hold: metadata is immediately inspectable, every unrelated lease
//! excludes the delivery, and the FIFO supervisor releases it only after the
//! exact attempt baseline is durable. Generalized waits reference opaque
//! assignment, worker-invocation, or reply handles and therefore do not create
//! cross-database foreign keys. The runtime resolves those handles into exact
//! internal dependency identities and immutable mixed-execution edges before
//! registration. EventStore seals the exact per-wait edge set before
//! publishing those normalized edges, so replay cannot mutate even an
//! originally empty topology. It then rejects a
//! self, ancestor, reciprocal-reply, or mixed dependency cycle in the same
//! writer transaction that would otherwise admit the wait. Registration pins
//! the caller's causal trace and autonomous hop; unrelated target completions
//! can satisfy the fan-in but never replace its continuation provenance. A satisfied wait is atomically
//! bound either to the registering tool result or, for later satisfaction, to
//! one aggregate message. This closes the resolver-to-wake crash boundary
//! without reopening any terminal member or delivering the same resolution
//! through both paths.

use std::collections::BTreeSet;
use std::io;

use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::identity::EventIdentity;
use crate::domains::session::event_store::sqlite::repositories::event::EventRepo;
use crate::domains::session::event_store::sqlite::repositories::session::SessionRepo;
use crate::domains::session::event_store::types::EventType;
use crate::shared::protocol::messages::{
    AgentMessageAuthority, AgentMessageContent, AgentMessageKind,
};

use super::event_log::append_event_in_tx_with_identity;
use super::{AppendOptions, EventStore};

const MAX_WAIT_MEMBERS: usize = 32;
const MAX_WAIT_DEPENDENCY_EDGES: usize = 1_024;
const MAX_IDEMPOTENCY_BYTES: usize = 256;
const MAX_CHANNEL_BYTES: usize = 256;
const MAX_EVIDENCE_BYTES: usize = 40_000;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentMessageDisposition {
    Pending,
    Materialized,
    Observed,
    Cancelled,
}

impl AgentMessageDisposition {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "materialized" => Some(Self::Materialized),
            "observed" => Some(Self::Observed),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentMessageMetadata {
    pub(crate) idempotency_key: String,
    pub(crate) channel_id: String,
    /// Optional explicit replay identity. Production callers leave this unset;
    /// the store allocates the next channel sequence under writer intent.
    pub(crate) channel_sequence: Option<u64>,
    pub(crate) source_session_id: Option<String>,
    pub(crate) target_agent_id: String,
    pub(crate) target_session_id: String,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) content: AgentMessageContent,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentMessageMetadataRecord {
    pub(crate) message_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) channel_id: String,
    pub(crate) channel_sequence: u64,
    pub(crate) source_agent_id: String,
    pub(crate) source_session_id: Option<String>,
    pub(crate) target_agent_id: String,
    pub(crate) target_session_id: String,
    pub(crate) kind: AgentMessageKind,
    pub(crate) authority: AgentMessageAuthority,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) assignment_id: Option<String>,
    pub(crate) reply_to_message_id: Option<String>,
    pub(crate) content: AgentMessageContent,
    pub(crate) disposition: AgentMessageDisposition,
    pub(crate) materialized_event_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) materialized_at: Option<String>,
    pub(crate) observed_at: Option<String>,
    pub(crate) cancelled_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct MaterializedAgentMessage {
    pub(crate) metadata: AgentMessageMetadataRecord,
    pub(crate) content: AgentMessageContent,
    pub(crate) event: EventRow,
    pub(crate) created: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentCorrespondentRecord {
    pub(crate) agent_id: String,
    pub(crate) last_message_at: String,
    pub(crate) message_count: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentMessageMetadataPage {
    pub(crate) items: Vec<AgentMessageMetadataRecord>,
    pub(crate) total: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentCorrespondentPage {
    pub(crate) items: Vec<AgentCorrespondentRecord>,
    pub(crate) total: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CoordinationWaitMode {
    All,
    Any,
}

impl CoordinationWaitMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Any => "any",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "all" => Some(Self::All),
            "any" => Some(Self::Any),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CoordinationTargetKind {
    AgentAssignment,
    WorkerInvocation,
    Reply,
}

impl CoordinationTargetKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::AgentAssignment => "agent_assignment",
            Self::WorkerInvocation => "worker_invocation",
            Self::Reply => "reply",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "agent_assignment" => Some(Self::AgentAssignment),
            "worker_invocation" => Some(Self::WorkerInvocation),
            "reply" => Some(Self::Reply),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoordinationWaitTarget {
    pub(crate) kind: CoordinationTargetKind,
    pub(crate) id: String,
}

/// One immutable dependency endpoint resolved by the Engine owner of an
/// opaque model handle. A member retains its original handle for result
/// reconciliation while cycle detection uses only `dependency_id`.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct CoordinationWaitDependency {
    pub(crate) target: CoordinationWaitTarget,
    pub(crate) dependency_id: String,
}

/// One immutable edge in the mixed execution topology. `causal` means a
/// structured parent joins its descendant; `executor` means an assignment or
/// direct-agent execution requires the stable agent scheduler that runs it.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct CoordinationDependencyEdge {
    pub(crate) source_dependency_id: String,
    pub(crate) target_dependency_id: String,
    pub(crate) kind: CoordinationDependencyEdgeKind,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) enum CoordinationDependencyEdgeKind {
    Causal,
    Executor,
}

impl CoordinationDependencyEdgeKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Causal => "causal",
            Self::Executor => "executor",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct NewCoordinationWait {
    pub(crate) idempotency_key: String,
    pub(crate) session_id: String,
    pub(crate) owner_agent_id: String,
    pub(crate) owner_assignment_id: Option<String>,
    /// Immutable causal trace of the registering agent turn. Completion
    /// targets may belong to unrelated traces and must not replace it.
    pub(crate) trace_id: String,
    /// Autonomous hop observed at registration. The aggregate continuation,
    /// when needed, advances exactly this value once.
    pub(crate) autonomous_hop: u32,
    pub(crate) mode: CoordinationWaitMode,
    pub(crate) targets: Vec<CoordinationWaitTarget>,
    /// Stable coordination identity of the calling agent. Executions which
    /// require that agent are linked through `dependency_edges`.
    pub(crate) owner_dependency_id: String,
    /// Exact normalized dependency for every member, in target order.
    pub(crate) dependencies: Vec<CoordinationWaitDependency>,
    /// Immutable causal/executor topology required to compare these endpoints
    /// with earlier pending waits after restart.
    pub(crate) dependency_edges: Vec<CoordinationDependencyEdge>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoordinationWaitRecord {
    pub(crate) wait_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) session_id: String,
    pub(crate) owner_agent_id: String,
    pub(crate) owner_assignment_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) mode: CoordinationWaitMode,
    pub(crate) disposition: String,
    pub(crate) aggregate_message_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) resolved_at: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoordinationWaitMemberRecord {
    pub(crate) wait_id: String,
    pub(crate) target: CoordinationWaitTarget,
    pub(crate) ordinal: u32,
    pub(crate) disposition: String,
    pub(crate) terminal_status: Option<String>,
    pub(crate) evidence_reference: Option<Value>,
    pub(crate) resolved_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct CoordinationTerminalEvidence {
    pub(crate) target: CoordinationWaitTarget,
    pub(crate) status: String,
    pub(crate) evidence_reference: Value,
}

#[derive(Clone, Debug)]
pub(crate) struct CoordinationWaitResolution {
    pub(crate) wait: CoordinationWaitRecord,
    pub(crate) satisfied: Vec<CoordinationWaitMemberRecord>,
}

/// Result of one atomic wait registration. A terminal handle may have crossed
/// from `workers.sqlite` before registration or may already have been imported
/// into EventStore delivery state. Returning the resolution beside the wait
/// lets the caller continue synchronously without polling or manufacturing a
/// second completion wake.
#[derive(Clone, Debug)]
pub(crate) struct CoordinationWaitAdmission {
    pub(crate) wait: CoordinationWaitRecord,
    pub(crate) resolution: Option<CoordinationWaitResolution>,
}

#[derive(Clone, Debug)]
enum ImportedCoordinationTerminal {
    AgentMessage {
        evidence: CoordinationTerminalEvidence,
        message_id: String,
        created_at: String,
    },
    WorkerDelivery {
        evidence: CoordinationTerminalEvidence,
        delivery_id: String,
        created_at: String,
    },
}

impl ImportedCoordinationTerminal {
    fn evidence(&self) -> &CoordinationTerminalEvidence {
        match self {
            Self::AgentMessage { evidence, .. } | Self::WorkerDelivery { evidence, .. } => evidence,
        }
    }

    fn created_at(&self) -> &str {
        match self {
            Self::AgentMessage { created_at, .. } | Self::WorkerDelivery { created_at, .. } => {
                created_at
            }
        }
    }
}

const MESSAGE_COLUMNS: &str = "
    message_id,idempotency_key,channel_id,channel_sequence,source_agent_id,
    source_session_id,target_agent_id,target_session_id,kind,authority,trace_id,
    autonomous_hop,assignment_id,reply_to_message_id,content_json,disposition,
    materialized_event_id,created_at,materialized_at,observed_at,cancelled_at
";
const WAIT_COLUMNS: &str = "
    wait_id,idempotency_key,session_id,owner_agent_id,owner_assignment_id,
    trace_id,autonomous_hop,mode,disposition,aggregate_message_id,created_at,resolved_at
";
const MEMBER_COLUMNS: &str = "
    wait_id,target_kind,target_id,ordinal,disposition,terminal_status,
    evidence_reference_json,resolved_at
";

impl EventStore {
    /// Persist a canonical outgoing message before recipient scheduling. This
    /// never appends to the recipient transcript; safe-boundary materialization
    /// is a separate idempotent operation.
    pub(crate) fn record_agent_message(
        &self,
        request: &NewAgentMessageMetadata,
    ) -> Result<AgentMessageMetadataRecord> {
        validate_message(request)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let _ = SessionRepo::get_by_id(&transaction, &request.target_session_id)?.ok_or_else(
                || EventStoreError::SessionNotFound(request.target_session_id.clone()),
            )?;
            if let Some(source_session_id) = request.source_session_id.as_deref()
                && SessionRepo::get_by_id(&transaction, source_session_id)?.is_none()
            {
                return Err(EventStoreError::SessionNotFound(
                    source_session_id.to_owned(),
                ));
            }
            if request.content.kind == AgentMessageKind::Answer {
                validate_answer_correlation(&transaction, request)?;
            }
            let now = chrono::Utc::now().to_rfc3339();
            let channel_sequence = match request.channel_sequence {
                Some(sequence) => sequence,
                None => transaction.query_row(
                    "SELECT COALESCE(MAX(channel_sequence),-1)+1
                     FROM agent_message_metadata WHERE channel_id=?1",
                    [&request.channel_id],
                    |row| row.get::<_, u64>(0),
                )?,
            };
            transaction.execute(
                "INSERT OR IGNORE INTO agent_message_metadata(
                    message_id,idempotency_key,channel_id,channel_sequence,source_agent_id,
                    source_session_id,target_agent_id,target_session_id,kind,authority,
                    trace_id,autonomous_hop,assignment_id,reply_to_message_id,
                    content_json,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
                params![
                    request.content.message_id,
                    request.idempotency_key,
                    request.channel_id,
                    channel_sequence,
                    request.content.source_agent_id,
                    request.source_session_id,
                    request.target_agent_id,
                    request.target_session_id,
                    enum_string(&request.content.kind)?,
                    enum_string(&request.content.authority)?,
                    request.trace_id,
                    request.autonomous_hop,
                    request.content.assignment_id,
                    request.content.reply_to,
                    serde_json::to_string(&request.content)?,
                    now,
                ],
            )?;
            let metadata = query_message_by_key(&transaction, &request.idempotency_key)?
                .ok_or_else(|| {
                    EventStoreError::Internal("agent message metadata disappeared".to_owned())
                })?;
            validate_message_replay(&metadata, request)?;
            transaction.commit()?;
            Ok(metadata)
        })
    }

    /// Materialize one pending message at a recipient provider-safe boundary.
    /// The event append and metadata binding commit atomically.
    pub(crate) fn materialize_agent_message(
        &self,
        message_id: &str,
    ) -> Result<MaterializedAgentMessage> {
        let target_session_id = {
            let connection = self.conn()?;
            query_message(&connection, message_id)?
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent message '{message_id}' was not found"
                    ))
                })?
                .target_session_id
        };
        self.with_session_write_lock(&target_session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let mut metadata = query_message(&transaction, message_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!(
                    "agent message '{message_id}' was not found"
                ))
            })?;
            if metadata.disposition == AgentMessageDisposition::Cancelled {
                return Err(EventStoreError::InvalidOperation(format!(
                    "agent message '{message_id}' was cancelled before materialization"
                )));
            }
            if let Some(event_id) = metadata.materialized_event_id.as_deref() {
                let event = EventRepo::get_by_id(&transaction, event_id)?
                    .ok_or_else(|| EventStoreError::EventNotFound(event_id.to_owned()))?;
                let content = metadata.content.clone();
                transaction.commit()?;
                return Ok(MaterializedAgentMessage {
                    metadata,
                    content,
                    event,
                    created: false,
                });
            }
            let target = SessionRepo::get_by_id(&transaction, &target_session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(target_session_id.clone()))?;
            let now = chrono::Utc::now().to_rfc3339();
            let appended = append_event_in_tx_with_identity(
                &transaction,
                &target,
                &AppendOptions {
                    session_id: &target_session_id,
                    event_type: EventType::MessageAgent,
                    payload: serde_json::json!({"content":metadata.content}),
                    parent_id: None,
                    sequence: None,
                },
                EventIdentity::generate_current(),
            )?;
            transaction.execute(
                "UPDATE agent_message_metadata
                 SET disposition='materialized',materialized_event_id=?2,materialized_at=?3
                 WHERE message_id=?1 AND disposition='pending'",
                params![message_id, appended.id, now],
            )?;
            metadata = query_message(&transaction, message_id)?.ok_or_else(|| {
                EventStoreError::Internal("materialized agent message disappeared".to_owned())
            })?;
            let event = EventRepo::get_by_id(&transaction, &appended.id)?
                .ok_or_else(|| EventStoreError::EventNotFound(appended.id.clone()))?;
            let content = metadata.content.clone();
            transaction.commit()?;
            Ok(MaterializedAgentMessage {
                metadata,
                content,
                event,
                created: true,
            })
        })
    }

    #[cfg(test)]
    pub(crate) fn observe_agent_messages(
        &self,
        target_session_id: &str,
        message_ids: &[String],
    ) -> Result<usize> {
        if message_ids.is_empty() {
            return Ok(0);
        }
        self.with_session_write_lock(target_session_id, || {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            let mut changed = 0;
            for message_id in message_ids {
                changed += connection.execute(
                    "UPDATE agent_message_metadata
                     SET disposition='observed',observed_at=?3
                     WHERE message_id=?1 AND target_session_id=?2
                       AND disposition='materialized'",
                    params![message_id, target_session_id, now],
                )?;
            }
            Ok(changed)
        })
    }

    /// Cancel a message only while it is still pending safe-boundary
    /// materialization. Transcript events are immutable once appended.
    #[cfg(test)]
    pub(crate) fn cancel_pending_agent_message(&self, message_id: &str) -> Result<bool> {
        let target_session_id = {
            let connection = self.conn()?;
            query_message(&connection, message_id)?
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent message '{message_id}' was not found"
                    ))
                })?
                .target_session_id
        };
        self.with_session_write_lock(&target_session_id, || {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            connection
                .execute(
                    "UPDATE agent_message_metadata
                     SET disposition='cancelled',cancelled_at=?2
                     WHERE message_id=?1 AND disposition='pending'",
                    params![message_id, now],
                )
                .map(|changed| changed == 1)
                .map_err(EventStoreError::from)
        })
    }

    /// Count-backed unread/actionable message page for bounded Team Context.
    /// Observation state, not a fixed recent-message window, defines the set.
    pub(crate) fn unobserved_agent_message_page(
        &self,
        target_session_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<AgentMessageMetadataPage> {
        let connection = self.conn()?;
        let total = connection.query_row(
            "SELECT COUNT(*) FROM agent_message_metadata
             WHERE target_session_id=?1 AND disposition NOT IN ('observed','cancelled')",
            [target_session_id],
            |row| row.get::<_, u64>(0),
        )?;
        let mut statement = connection.prepare(&format!(
            "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
             WHERE target_session_id=?1 AND disposition NOT IN ('observed','cancelled')
             ORDER BY created_at DESC,message_id DESC LIMIT ?2 OFFSET ?3"
        ))?;
        let items = statement
            .query_map(
                params![
                    target_session_id,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_message,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(AgentMessageMetadataPage { items, total })
    }

    /// Pending safe-boundary work in deterministic delivery order. The
    /// materializer rechecks each row under the target session write lock, so
    /// concurrent callers may safely receive overlapping read pages.
    #[cfg(test)]
    pub(crate) fn list_pending_agent_messages_for_session(
        &self,
        target_session_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentMessageMetadataRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(&format!(
            "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
             WHERE target_session_id=?1 AND disposition='pending'
             ORDER BY created_at,channel_id,channel_sequence,message_id LIMIT ?2"
        ))?;
        statement
            .query_map(
                params![
                    target_session_id,
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256),
                ],
                map_message,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn agent_message_metadata(
        &self,
        message_id: &str,
    ) -> Result<Option<AgentMessageMetadataRecord>> {
        let connection = self.conn()?;
        query_message(&connection, message_id)
    }

    /// Resolve the canonical work-admission message for an assignment. The
    /// FIFO supervisor treats this as its cross-store readiness boundary:
    /// accepted work cannot enter Running until its semantic task is durable
    /// in the recipient's message store.
    pub(crate) fn agent_assignment_admission_message_id(
        &self,
        target_session_id: &str,
        assignment_id: &str,
    ) -> Result<Option<String>> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT message_id FROM agent_message_metadata
                 WHERE target_session_id=?1 AND assignment_id=?2
                   AND kind IN ('instruction','request')
                 ORDER BY created_at,channel_sequence,message_id LIMIT 1",
                params![target_session_id, assignment_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(EventStoreError::from)
    }

    /// Promote one persisted assignment message from passive evidence to the
    /// exact wake owned by its FIFO supervisor. Callers invoke this only after
    /// the attempt baseline is durable. Replay is harmless: a delivery already
    /// leased or observed remains untouched and recovery uses continuity.
    pub(crate) fn activate_agent_assignment_message_delivery(
        &self,
        target_session_id: &str,
        assignment_id: &str,
        message_id: &str,
    ) -> Result<Option<String>> {
        self.with_session_write_lock(target_session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let (message_target, message_assignment) = transaction
                .query_row(
                    "SELECT target_session_id,assignment_id
                     FROM agent_message_metadata WHERE message_id=?1",
                    [message_id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .optional()?
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent message '{message_id}' was not found"
                    ))
                })?;
            if message_target != target_session_id
                || message_assignment.as_deref() != Some(assignment_id)
            {
                return Err(EventStoreError::InvalidOperation(
                    "assignment message target or assignment mismatch".to_owned(),
                ));
            }
            let idempotency_key = format!("agent-message-delivery:{message_id}");
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agent_assignment_delivery_holds
                 SET state='released',released_at=COALESCE(released_at,?2)
                 WHERE assignment_id=?1 AND state='held'",
                params![assignment_id, now],
            )?;
            transaction.execute(
                "UPDATE agent_deliveries
                 SET wake_policy='wake',next_wake_at=NULL
                 WHERE idempotency_key=?1 AND target_session_id=?2
                   AND disposition='pending' AND leased_run_id IS NULL",
                params![idempotency_key, target_session_id],
            )?;
            let delivery_id = transaction
                .query_row(
                    "SELECT delivery_id FROM agent_deliveries
                     WHERE idempotency_key=?1 AND target_session_id=?2
                       AND disposition='pending' AND wake_policy='wake'
                     LIMIT 1",
                    params![idempotency_key, target_session_id],
                    |row| row.get(0),
                )
                .optional()?;
            transaction.commit()?;
            Ok(delivery_id)
        })
    }

    /// Bidirectional, cursor-stable communication history for one profile
    /// agent. `before` is the exact `(createdAt,messageId)` pair returned by
    /// the final row of the previous page.
    pub(crate) fn list_agent_messages_for_participant(
        &self,
        agent_id: &str,
        before: Option<(&str, &str)>,
        limit: usize,
    ) -> Result<Vec<AgentMessageMetadataRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(&format!(
            "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
             WHERE (source_agent_id=?1 OR target_agent_id=?1)
               AND (?2 IS NULL OR created_at<?2 OR (created_at=?2 AND message_id<?3))
             ORDER BY created_at DESC,message_id DESC LIMIT ?4"
        ))?;
        statement
            .query_map(
                params![
                    agent_id,
                    before.map(|value| value.0),
                    before.map(|value| value.1),
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                ],
                map_message,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    #[cfg(test)]
    pub(crate) fn list_agent_correspondents(
        &self,
        agent_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentCorrespondentRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(
            "SELECT
                CASE WHEN source_agent_id=?1 THEN target_agent_id ELSE source_agent_id END,
                MAX(created_at),COUNT(*)
             FROM agent_message_metadata
             WHERE source_agent_id=?1 OR target_agent_id=?1
             GROUP BY 1 ORDER BY 2 DESC,1 LIMIT ?2",
        )?;
        statement
            .query_map(
                params![agent_id, i64::try_from(limit.clamp(1, 200)).unwrap_or(200)],
                |row| {
                    Ok(AgentCorrespondentRecord {
                        agent_id: row.get(0)?,
                        last_message_at: row.get(1)?,
                        message_count: row.get(2)?,
                    })
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    /// Count-backed correspondent page with an explicit exclusion set. Team
    /// Context uses exclusions to avoid counting parent/children twice; native
    /// relationship projections use the same durable communication edge set.
    pub(crate) fn agent_correspondent_page(
        &self,
        agent_id: &str,
        excluded_agent_ids: &[String],
        offset: usize,
        limit: usize,
    ) -> Result<AgentCorrespondentPage> {
        let connection = self.conn()?;
        let excluded = serde_json::to_string(excluded_agent_ids).map_err(|error| {
            EventStoreError::Internal(format!("encode correspondent exclusions: {error}"))
        })?;
        let cte = "WITH edges(other_agent_id,created_at) AS (
                SELECT CASE WHEN source_agent_id=?1 THEN target_agent_id ELSE source_agent_id END,
                       created_at
                FROM agent_message_metadata
                WHERE source_agent_id=?1 OR target_agent_id=?1
             ), summaries(other_agent_id,last_message_at,message_count) AS (
                SELECT other_agent_id,MAX(created_at),COUNT(*) FROM edges
                WHERE other_agent_id NOT IN (SELECT value FROM json_each(?2))
                GROUP BY other_agent_id
             )";
        let total = connection.query_row(
            &format!("{cte} SELECT COUNT(*) FROM summaries"),
            params![agent_id, excluded],
            |row| row.get::<_, u64>(0),
        )?;
        let mut statement = connection.prepare(&format!(
            "{cte}
             SELECT other_agent_id,last_message_at,message_count FROM summaries
             ORDER BY last_message_at DESC,other_agent_id LIMIT ?3 OFFSET ?4"
        ))?;
        let items = statement
            .query_map(
                params![
                    agent_id,
                    excluded,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                |row| {
                    Ok(AgentCorrespondentRecord {
                        agent_id: row.get(0)?,
                        last_message_at: row.get(1)?,
                        message_count: row.get(2)?,
                    })
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(AgentCorrespondentPage { items, total })
    }

    /// Exact terminal reply evidence. Wait reconciliation must not depend on
    /// an arbitrary recent-message page when a durable question may be old.
    pub(crate) fn answer_for_agent_question(
        &self,
        recipient_agent_id: &str,
        question_message_id: &str,
    ) -> Result<Option<AgentMessageMetadataRecord>> {
        let connection = self.conn()?;
        connection
            .query_row(
                &format!(
                    "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
                     WHERE kind='answer' AND reply_to_message_id=?1
                       AND target_agent_id=?2
                     ORDER BY created_at DESC,message_id DESC LIMIT 1"
                ),
                params![question_message_id, recipient_agent_id],
                map_message,
            )
            .optional()
            .map_err(EventStoreError::from)
    }

    pub(crate) fn coordination_message_count(&self, trace_id: &str) -> Result<u32> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT COUNT(*) FROM agent_message_metadata WHERE trace_id=?1",
                [trace_id],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    /// Return uncapped durable autonomy truth for one assignment. Runtime
    /// result continuation must advance the highest observed hop; bounded
    /// transcript projections are not a safe scheduler input.
    pub(crate) fn max_agent_message_autonomous_hop(&self, assignment_id: &str) -> Result<u32> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT COALESCE(MAX(autonomous_hop),0)
                 FROM agent_message_metadata WHERE assignment_id=?1",
                [assignment_id],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    pub(crate) fn create_coordination_wait(
        &self,
        request: &NewCoordinationWait,
        initial_terminals: &[CoordinationTerminalEvidence],
    ) -> Result<CoordinationWaitAdmission> {
        validate_wait(request)?;
        validate_coordination_terminals(initial_terminals)?;
        let requested_targets = request.targets.iter().collect::<BTreeSet<_>>();
        let mut initial_targets = BTreeSet::new();
        for terminal in initial_terminals {
            if !requested_targets.contains(&terminal.target) {
                return Err(EventStoreError::InvalidOperation(format!(
                    "initial coordination terminal is not a requested target: {}:{}",
                    terminal.target.kind.as_str(),
                    terminal.target.id
                )));
            }
            if !initial_targets.insert(&terminal.target) {
                return Err(EventStoreError::InvalidOperation(format!(
                    "duplicate initial coordination terminal: {}:{}",
                    terminal.target.kind.as_str(),
                    terminal.target.id
                )));
            }
        }
        self.with_session_write_lock(&request.session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let _ = SessionRepo::get_by_id(&transaction, &request.session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(request.session_id.clone()))?;
            let wait_id = format!("coordination_wait_{}", uuid::Uuid::now_v7());
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "INSERT OR IGNORE INTO coordination_waits(
                    wait_id,idempotency_key,session_id,owner_agent_id,
                    owner_assignment_id,trace_id,autonomous_hop,mode,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                params![
                    wait_id,
                    request.idempotency_key,
                    request.session_id,
                    request.owner_agent_id,
                    request.owner_assignment_id,
                    request.trace_id,
                    request.autonomous_hop,
                    request.mode.as_str(),
                    now,
                ],
            )?;
            let record =
                query_wait_by_key(&transaction, &request.idempotency_key)?.ok_or_else(|| {
                    EventStoreError::Internal("coordination wait disappeared".to_owned())
                })?;
            validate_wait_replay(&record, request)?;
            let member_count = transaction.query_row(
                "SELECT COUNT(*) FROM coordination_wait_members WHERE wait_id=?1",
                [&record.wait_id],
                |row| row.get::<_, usize>(0),
            )?;
            if member_count == 0 && record.disposition == "pending" {
                for (ordinal, target) in request.targets.iter().enumerate() {
                    transaction.execute(
                        "INSERT INTO coordination_wait_members(
                            wait_id,target_kind,target_id,ordinal
                         ) VALUES (?1,?2,?3,?4)",
                        params![record.wait_id, target.kind.as_str(), target.id, ordinal],
                    )?;
                }
            } else {
                let existing_targets = query_wait_members_in_tx(&transaction, &record.wait_id)?
                    .into_iter()
                    .map(|member| member.target)
                    .collect::<Vec<_>>();
                if existing_targets != request.targets {
                    return Err(EventStoreError::InvalidOperation(
                        "coordination wait idempotency conflict".to_owned(),
                    ));
                }
            }
            persist_coordination_wait_topology_in_tx(&transaction, &record.wait_id, request)?;

            // Completion can cross the workers/EventStore boundary between
            // the caller's terminal snapshot and this writer transaction. An
            // already-imported, still-unobserved completion is stronger local
            // evidence and carries the exact representation its importer will
            // replay later. Process imported evidence by arrival time first so
            // `any` has deterministic first-completion semantics; remaining
            // initial evidence follows caller target order.
            let mut imported = request
                .targets
                .iter()
                .map(|target| {
                    imported_coordination_terminal_in_tx(&transaction, &request.session_id, target)
                })
                .collect::<Result<Vec<_>>>()?
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            validate_coordination_terminals(
                &imported
                    .iter()
                    .map(|terminal| terminal.evidence().clone())
                    .collect::<Vec<_>>(),
            )?;
            imported.sort_by(|left, right| {
                left.created_at()
                    .cmp(right.created_at())
                    .then_with(|| {
                        left.evidence()
                            .target
                            .kind
                            .as_str()
                            .cmp(right.evidence().target.kind.as_str())
                    })
                    .then_with(|| left.evidence().target.id.cmp(&right.evidence().target.id))
            });
            let imported_targets = imported
                .iter()
                .map(|terminal| terminal.evidence().target.clone())
                .collect::<BTreeSet<_>>();
            let mut ordered_evidence = imported
                .iter()
                .map(|terminal| terminal.evidence().clone())
                .collect::<Vec<_>>();
            for target in &request.targets {
                if imported_targets.contains(target) {
                    continue;
                }
                if let Some(terminal) = initial_terminals
                    .iter()
                    .find(|terminal| terminal.target == *target)
                {
                    ordered_evidence.push(terminal.clone());
                }
            }
            let now = chrono::Utc::now().to_rfc3339();
            for terminal in &ordered_evidence {
                apply_coordination_terminal_to_wait_in_tx(
                    &transaction,
                    &record.wait_id,
                    terminal,
                    &now,
                )?;
                resolve_coordination_wait_in_tx(&transaction, &record.wait_id, &now)?;
            }
            for terminal in &imported {
                if wait_member_is_satisfied_in_tx(
                    &transaction,
                    &record.wait_id,
                    &terminal.evidence().target,
                )? {
                    absorb_imported_coordination_terminal_in_tx(
                        &transaction,
                        &request.session_id,
                        terminal,
                        &now,
                    )?;
                }
            }
            // Cycle membership is exactly the still-pending dependency set.
            // A terminal handle consumed by this registration cannot deadlock
            // its caller, so immediate reconciliation intentionally precedes
            // this check. The write transaction still commits neither the wait
            // nor its imported evidence if any remaining edge is cyclic.
            if query_wait_by_id(&transaction, &record.wait_id)?
                .is_some_and(|wait| wait.disposition == "pending")
            {
                ensure_pending_wait_topology_complete_in_tx(&transaction)?;
                if coordination_wait_has_cycle_in_tx(&transaction, &record.wait_id)? {
                    return Err(EventStoreError::InvalidOperation(
                        "AGENT_WAIT_CYCLE: coordination wait would create a durable cycle"
                            .to_owned(),
                    ));
                }
            }
            let wait = query_wait_by_id(&transaction, &record.wait_id)?.ok_or_else(|| {
                EventStoreError::Internal("coordination wait disappeared".to_owned())
            })?;
            let resolution = query_unbound_wait_resolution_in_tx(&transaction, &wait.wait_id)?;
            if resolution.is_some() {
                // INVARIANT: registration and immediate resolution consumption
                // are one transaction. A completion that is returned in the
                // current `agent_wait` tool result can therefore never be
                // rediscovered later as an aggregate autonomous wake.
                transaction.execute(
                    "INSERT OR IGNORE INTO coordination_wait_inline_results(
                        wait_id,consumer_key,consumed_at
                     ) VALUES (?1,?2,?3)",
                    params![wait.wait_id, request.idempotency_key, now],
                )?;
                let consumer_key = transaction.query_row(
                    "SELECT consumer_key FROM coordination_wait_inline_results WHERE wait_id=?1",
                    [&wait.wait_id],
                    |row| row.get::<_, String>(0),
                )?;
                if consumer_key != request.idempotency_key {
                    return Err(EventStoreError::InvalidOperation(
                        "coordination wait resolution already belongs to another consumer"
                            .to_owned(),
                    ));
                }
            }
            transaction.commit()?;
            Ok(CoordinationWaitAdmission { wait, resolution })
        })
    }

    pub(crate) fn list_coordination_waits(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<CoordinationWaitRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(&format!(
            "SELECT {WAIT_COLUMNS} FROM coordination_waits
             WHERE session_id=?1 ORDER BY created_at DESC,wait_id DESC LIMIT ?2"
        ))?;
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

    /// Exact durable wait state for scheduler reconciliation. Presentation
    /// pages are intentionally not used at the registration/parking boundary.
    pub(crate) fn coordination_wait(
        &self,
        wait_id: &str,
    ) -> Result<Option<CoordinationWaitRecord>> {
        let connection = self.conn()?;
        query_wait_by_id(&connection, wait_id)
    }

    pub(crate) fn coordination_wait_members(
        &self,
        wait_id: &str,
    ) -> Result<Vec<CoordinationWaitMemberRecord>> {
        let connection = self.conn()?;
        let mut statement = connection.prepare(&format!(
            "SELECT {MEMBER_COLUMNS} FROM coordination_wait_members
             WHERE wait_id=?1 ORDER BY ordinal"
        ))?;
        statement
            .query_map([wait_id], map_member)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(EventStoreError::from)
    }

    /// Whether one recipient's ordinary per-target delivery is owned by that
    /// same recipient's explicit fan-in.
    ///
    /// A target is not globally consumed: another participant or bounded
    /// manager may independently wait on the same handle without stealing the
    /// original delegator's automatic result. Callers with a stable agent
    /// identity provide it as an additional ownership check; legacy
    /// session-originated worker results can use the exact session alone.
    /// A satisfied member remains an ownership marker after its wait resolves,
    /// because terminal-outbox replay must not manufacture the individual wake
    /// that the aggregate replaced. Released `any` members and cancelled waits
    /// return to ordinary automatic delivery.
    pub(crate) fn coordination_wait_owns_automatic_delivery(
        &self,
        target: &CoordinationWaitTarget,
        recipient_session_id: &str,
        recipient_agent_id: Option<&str>,
    ) -> Result<bool> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM coordination_wait_members member
                    JOIN coordination_waits wait USING(wait_id)
                    WHERE member.target_kind=?1 AND member.target_id=?2
                      AND member.disposition IN ('pending','satisfied')
                      AND wait.disposition IN ('pending','satisfied')
                      AND wait.session_id=?3
                      AND (?4 IS NULL OR wait.owner_agent_id=?4)
                 )",
                params![
                    target.kind.as_str(),
                    target.id,
                    recipient_session_id,
                    recipient_agent_id,
                ],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    /// Cross-store management callers use this bounded existence check before
    /// a quiescent configure, close, role upgrade, or promotion. The
    /// `workers.sqlite` mutation still rechecks its own assignment/resource
    /// facts under writer intent; neither database transaction spans the other.
    pub(crate) fn has_pending_coordination_wait_for_agent(&self, agent_id: &str) -> Result<bool> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM coordination_waits
                    WHERE owner_agent_id=?1 AND disposition='pending'
                 )",
                [agent_id],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    /// Exact assignment-scoped join check. Unlike presentation reads this is
    /// intentionally unpaged: lifecycle decisions must account for every
    /// historical wait owned by the assignment.
    pub(crate) fn has_pending_coordination_wait_for_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<bool> {
        let connection = self.conn()?;
        connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM coordination_waits
                    WHERE owner_assignment_id=?1 AND disposition='pending'
                 )",
                [assignment_id],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    /// Cancel every pending wait owned by one assignment in a single durable
    /// operation. This lifecycle API is deliberately unbounded; using the
    /// paged audit listing here could strand older waits once an assignment has
    /// accumulated more than the UI page limit.
    pub(crate) fn cancel_coordination_waits_for_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<usize> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE coordination_wait_members
                 SET disposition='released',resolved_at=?2
                 WHERE disposition='pending' AND EXISTS(
                    SELECT 1 FROM coordination_waits wait
                    WHERE wait.wait_id=coordination_wait_members.wait_id
                      AND wait.owner_assignment_id=?1
                      AND wait.disposition='pending'
                 )",
                params![assignment_id, now],
            )?;
            let changed = transaction.execute(
                "UPDATE coordination_waits
                 SET disposition='cancelled',resolved_at=?2
                 WHERE owner_assignment_id=?1 AND disposition='pending'",
                params![assignment_id, now],
            )?;
            transaction.commit()?;
            Ok(changed)
        })
    }

    /// Apply terminal evidence and resolve ready `all`/`any` fan-ins in one
    /// transaction. The caller creates exactly one aggregate result message
    /// for each returned resolution, then binds its message id separately.
    pub(crate) fn reconcile_coordination_waits(
        &self,
        terminals: &[CoordinationTerminalEvidence],
    ) -> Result<Vec<CoordinationWaitResolution>> {
        validate_coordination_terminals(terminals)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            for terminal in terminals {
                apply_coordination_terminal_globally_in_tx(&transaction, terminal, &now)?;
                // Resolve after each arrival so `any` releases its remaining
                // members on the first deterministic terminal rather than
                // accidentally satisfying every member in one import batch.
                resolve_all_pending_coordination_waits_in_tx(&transaction, &now)?;
            }
            // A crash may occur after the wait commits satisfied but before
            // its aggregate message is recorded and bound. Returning every
            // unbound resolution on each reconciliation makes that boundary
            // recoverable without reopening terminal members or polling.
            let unbound_waits = {
                let mut statement = transaction.prepare(&format!(
                    "SELECT {WAIT_COLUMNS} FROM coordination_waits
                     WHERE disposition='satisfied' AND aggregate_message_id IS NULL
                       AND NOT EXISTS(
                        SELECT 1 FROM coordination_wait_inline_results inline_result
                        WHERE inline_result.wait_id=coordination_waits.wait_id
                       )
                     ORDER BY resolved_at,wait_id"
                ))?;
                statement
                    .query_map([], map_wait)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            let mut resolutions = Vec::with_capacity(unbound_waits.len());
            for wait in unbound_waits {
                if let Some(resolution) =
                    query_unbound_wait_resolution_in_tx(&transaction, &wait.wait_id)?
                {
                    resolutions.push(resolution);
                }
            }
            transaction.commit()?;
            Ok(resolutions)
        })
    }

    pub(crate) fn bind_coordination_wait_message(
        &self,
        wait_id: &str,
        message_id: &str,
    ) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            let changed = connection.execute(
                "UPDATE coordination_waits SET aggregate_message_id=?2
                 WHERE wait_id=?1 AND disposition='satisfied'
                   AND (aggregate_message_id IS NULL OR aggregate_message_id=?2)",
                params![wait_id, message_id],
            )?;
            Ok(changed == 1)
        })
    }
}

fn validate_message(request: &NewAgentMessageMetadata) -> Result<()> {
    for (field, value, max) in [
        (
            "idempotency key",
            request.idempotency_key.as_str(),
            MAX_IDEMPOTENCY_BYTES,
        ),
        ("channel id", request.channel_id.as_str(), MAX_CHANNEL_BYTES),
        (
            "message id",
            request.content.message_id.as_str(),
            MAX_IDEMPOTENCY_BYTES,
        ),
        (
            "source agent id",
            request.content.source_agent_id.as_str(),
            MAX_IDEMPOTENCY_BYTES,
        ),
        (
            "target agent id",
            request.target_agent_id.as_str(),
            MAX_IDEMPOTENCY_BYTES,
        ),
        (
            "target session id",
            request.target_session_id.as_str(),
            MAX_IDEMPOTENCY_BYTES,
        ),
        ("trace id", request.trace_id.as_str(), MAX_IDEMPOTENCY_BYTES),
    ] {
        if value.trim().is_empty() || value.len() > max || value.chars().any(char::is_control) {
            return Err(EventStoreError::InvalidOperation(format!(
                "agent message {field} must contain 1..={max} bytes and no control characters"
            )));
        }
    }
    if request.content.text.trim().is_empty()
        || request.content.text.as_bytes().len() > MAX_EVIDENCE_BYTES
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "agent message text must contain 1..={MAX_EVIDENCE_BYTES} UTF-8 bytes"
        )));
    }
    if request.channel_id
        != canonical_agent_channel_id(&request.content.source_agent_id, &request.target_agent_id)
    {
        return Err(EventStoreError::InvalidOperation(
            "agent message channel does not match its participants".to_owned(),
        ));
    }
    if (request.content.kind == AgentMessageKind::Answer) != request.content.reply_to.is_some() {
        return Err(EventStoreError::InvalidOperation(
            "only agent answers require replyTo".to_owned(),
        ));
    }
    Ok(())
}

fn canonical_agent_channel_id(first: &str, second: &str) -> String {
    if first <= second {
        format!("agent_channel:{first}:{second}")
    } else {
        format!("agent_channel:{second}:{first}")
    }
}

fn validate_answer_correlation(
    transaction: &rusqlite::Transaction<'_>,
    request: &NewAgentMessageMetadata,
) -> Result<()> {
    let reply_to = request.content.reply_to.as_deref().ok_or_else(|| {
        EventStoreError::InvalidOperation("agent answer requires replyTo".to_owned())
    })?;
    let question = query_message(transaction, reply_to)?.ok_or_else(|| {
        EventStoreError::InvalidOperation(format!("agent question '{reply_to}' was not found"))
    })?;
    if question.kind != AgentMessageKind::Question
        || question.source_agent_id != request.target_agent_id
        || question.target_agent_id != request.content.source_agent_id
    {
        return Err(EventStoreError::InvalidOperation(
            "agent answer does not match the exact question sender/recipient pair".to_owned(),
        ));
    }
    Ok(())
}

fn validate_message_replay(
    record: &AgentMessageMetadataRecord,
    request: &NewAgentMessageMetadata,
) -> Result<()> {
    if record.message_id != request.content.message_id
        || record.channel_id != request.channel_id
        || request
            .channel_sequence
            .is_some_and(|sequence| record.channel_sequence != sequence)
        || record.source_agent_id != request.content.source_agent_id
        || record.source_session_id != request.source_session_id
        || record.target_agent_id != request.target_agent_id
        || record.target_session_id != request.target_session_id
        || record.kind != request.content.kind
        || record.authority != request.content.authority
        || record.trace_id != request.trace_id
        || record.autonomous_hop != request.autonomous_hop
        || record.assignment_id != request.content.assignment_id
        || record.reply_to_message_id != request.content.reply_to
        || record.content != request.content
    {
        return Err(EventStoreError::InvalidOperation(
            "agent message idempotency conflict".to_owned(),
        ));
    }
    Ok(())
}

fn validate_wait(request: &NewCoordinationWait) -> Result<()> {
    if request.idempotency_key.trim().is_empty()
        || request.idempotency_key.len() > MAX_IDEMPOTENCY_BYTES
    {
        return Err(EventStoreError::InvalidOperation(
            "invalid coordination wait idempotency key".to_owned(),
        ));
    }
    if request.targets.is_empty() || request.targets.len() > MAX_WAIT_MEMBERS {
        return Err(EventStoreError::InvalidOperation(format!(
            "coordination wait requires 1..={MAX_WAIT_MEMBERS} targets"
        )));
    }
    if request.trace_id.trim().is_empty()
        || request.trace_id.as_bytes().len() > MAX_IDEMPOTENCY_BYTES
        || request.trace_id.chars().any(char::is_control)
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "coordination wait trace id must contain 1..={MAX_IDEMPOTENCY_BYTES} bytes and no control characters"
        )));
    }
    let unique = request
        .targets
        .iter()
        .map(|target| (target.kind.as_str(), target.id.as_str()))
        .collect::<BTreeSet<_>>();
    if unique.len() != request.targets.len() {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait contains duplicate targets".to_owned(),
        ));
    }
    for target in &request.targets {
        validate_wait_target(target)?;
    }
    validate_dependency_id(&request.owner_dependency_id)?;
    if request.dependencies.len() != request.targets.len()
        || request
            .dependencies
            .iter()
            .zip(&request.targets)
            .any(|(dependency, target)| dependency.target != *target)
    {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait dependencies must match targets in order".to_owned(),
        ));
    }
    for dependency in &request.dependencies {
        validate_dependency_id(&dependency.dependency_id)?;
    }
    if request.dependency_edges.len() > MAX_WAIT_DEPENDENCY_EDGES {
        return Err(EventStoreError::InvalidOperation(format!(
            "coordination wait exceeds {MAX_WAIT_DEPENDENCY_EDGES} topology edges"
        )));
    }
    let mut unique_edges = BTreeSet::new();
    for edge in &request.dependency_edges {
        validate_dependency_id(&edge.source_dependency_id)?;
        validate_dependency_id(&edge.target_dependency_id)?;
        if edge.source_dependency_id == edge.target_dependency_id {
            return Err(EventStoreError::InvalidOperation(
                "coordination dependency topology contains a self edge".to_owned(),
            ));
        }
        if !unique_edges.insert(edge) {
            return Err(EventStoreError::InvalidOperation(
                "coordination dependency topology contains duplicate edges".to_owned(),
            ));
        }
    }
    Ok(())
}

fn validate_wait_target(target: &CoordinationWaitTarget) -> Result<()> {
    if target.id.trim().is_empty()
        || target.id.as_bytes().len() > MAX_IDEMPOTENCY_BYTES
        || target.id.chars().any(char::is_control)
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "coordination wait target id must contain 1..={MAX_IDEMPOTENCY_BYTES} bytes and no control characters"
        )));
    }
    Ok(())
}

fn validate_dependency_id(dependency_id: &str) -> Result<()> {
    if dependency_id.trim().is_empty()
        || dependency_id.as_bytes().len() > 512
        || dependency_id.chars().any(char::is_control)
    {
        return Err(EventStoreError::InvalidOperation(
            "coordination dependency id must contain 1..=512 bytes and no control characters"
                .to_owned(),
        ));
    }
    Ok(())
}

fn validate_wait_replay(
    record: &CoordinationWaitRecord,
    request: &NewCoordinationWait,
) -> Result<()> {
    if record.session_id != request.session_id
        || record.owner_agent_id != request.owner_agent_id
        || record.owner_assignment_id != request.owner_assignment_id
        || record.trace_id != request.trace_id
        || record.autonomous_hop != request.autonomous_hop
        || record.mode != request.mode
    {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait idempotency conflict".to_owned(),
        ));
    }
    Ok(())
}

fn enum_string<T: Serialize>(value: &T) -> Result<String> {
    serde_json::to_value(value)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| {
            EventStoreError::Internal("coordination enum did not encode as text".to_owned())
        })
}

fn invalid_sql(index: usize, label: &str, value: &str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        index,
        rusqlite::types::Type::Text,
        Box::new(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown {label} '{value}'"),
        )),
    )
}

fn decode_enum<T: for<'de> Deserialize<'de>>(
    index: usize,
    label: &str,
    value: String,
) -> rusqlite::Result<T> {
    serde_json::from_value(Value::String(value.clone()))
        .map_err(|_| invalid_sql(index, label, &value))
}

fn map_message(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentMessageMetadataRecord> {
    let disposition = row.get::<_, String>(15)?;
    let content = serde_json::from_str::<AgentMessageContent>(&row.get::<_, String>(14)?).map_err(
        |error| {
            rusqlite::Error::FromSqlConversionFailure(
                14,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        },
    )?;
    Ok(AgentMessageMetadataRecord {
        message_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        channel_id: row.get(2)?,
        channel_sequence: row.get(3)?,
        source_agent_id: row.get(4)?,
        source_session_id: row.get(5)?,
        target_agent_id: row.get(6)?,
        target_session_id: row.get(7)?,
        kind: decode_enum(8, "agent message kind", row.get(8)?)?,
        authority: decode_enum(9, "agent message authority", row.get(9)?)?,
        trace_id: row.get(10)?,
        autonomous_hop: row.get(11)?,
        assignment_id: row.get(12)?,
        reply_to_message_id: row.get(13)?,
        content,
        disposition: AgentMessageDisposition::parse(&disposition)
            .ok_or_else(|| invalid_sql(15, "agent message disposition", &disposition))?,
        materialized_event_id: row.get(16)?,
        created_at: row.get(17)?,
        materialized_at: row.get(18)?,
        observed_at: row.get(19)?,
        cancelled_at: row.get(20)?,
    })
}

fn map_wait(row: &rusqlite::Row<'_>) -> rusqlite::Result<CoordinationWaitRecord> {
    let mode = row.get::<_, String>(7)?;
    Ok(CoordinationWaitRecord {
        wait_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        session_id: row.get(2)?,
        owner_agent_id: row.get(3)?,
        owner_assignment_id: row.get(4)?,
        trace_id: row.get(5)?,
        autonomous_hop: row.get(6)?,
        mode: CoordinationWaitMode::parse(&mode)
            .ok_or_else(|| invalid_sql(7, "coordination wait mode", &mode))?,
        disposition: row.get(8)?,
        aggregate_message_id: row.get(9)?,
        created_at: row.get(10)?,
        resolved_at: row.get(11)?,
    })
}

fn map_member(row: &rusqlite::Row<'_>) -> rusqlite::Result<CoordinationWaitMemberRecord> {
    let target_kind = row.get::<_, String>(1)?;
    let evidence = row
        .get::<_, Option<String>>(6)?
        .map(|value| {
            serde_json::from_str(&value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    6,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()?;
    Ok(CoordinationWaitMemberRecord {
        wait_id: row.get(0)?,
        target: CoordinationWaitTarget {
            kind: CoordinationTargetKind::parse(&target_kind)
                .ok_or_else(|| invalid_sql(1, "coordination target kind", &target_kind))?,
            id: row.get(2)?,
        },
        ordinal: row.get(3)?,
        disposition: row.get(4)?,
        terminal_status: row.get(5)?,
        evidence_reference: evidence,
        resolved_at: row.get(7)?,
    })
}

fn query_message(
    connection: &rusqlite::Connection,
    message_id: &str,
) -> Result<Option<AgentMessageMetadataRecord>> {
    connection
        .query_row(
            &format!("SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata WHERE message_id=?1"),
            [message_id],
            map_message,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_message_by_key(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<AgentMessageMetadataRecord>> {
    connection
        .query_row(
            &format!(
                "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata WHERE idempotency_key=?1"
            ),
            [key],
            map_message,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_wait_by_key(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<CoordinationWaitRecord>> {
    connection
        .query_row(
            &format!("SELECT {WAIT_COLUMNS} FROM coordination_waits WHERE idempotency_key=?1"),
            [key],
            map_wait,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_wait_by_id(
    connection: &rusqlite::Connection,
    wait_id: &str,
) -> Result<Option<CoordinationWaitRecord>> {
    connection
        .query_row(
            &format!("SELECT {WAIT_COLUMNS} FROM coordination_waits WHERE wait_id=?1"),
            [wait_id],
            map_wait,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_wait_members_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
) -> Result<Vec<CoordinationWaitMemberRecord>> {
    let mut statement = transaction.prepare(&format!(
        "SELECT {MEMBER_COLUMNS} FROM coordination_wait_members
         WHERE wait_id=?1 ORDER BY ordinal"
    ))?;
    statement
        .query_map([wait_id], map_member)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(EventStoreError::from)
}

fn validate_coordination_terminals(terminals: &[CoordinationTerminalEvidence]) -> Result<()> {
    for terminal in terminals {
        if terminal.status.trim().is_empty()
            || terminal.status.as_bytes().len() > MAX_IDEMPOTENCY_BYTES
            || terminal.status.chars().any(char::is_control)
        {
            return Err(EventStoreError::InvalidOperation(
                "coordination terminal status must be bounded printable text".to_owned(),
            ));
        }
        validate_wait_target(&terminal.target)?;
        let bytes = serde_json::to_vec(&terminal.evidence_reference)?.len();
        if bytes > MAX_EVIDENCE_BYTES {
            return Err(EventStoreError::InvalidOperation(format!(
                "coordination evidence exceeds {MAX_EVIDENCE_BYTES} bytes"
            )));
        }
    }
    Ok(())
}

fn imported_coordination_terminal_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    session_id: &str,
    target: &CoordinationWaitTarget,
) -> Result<Option<ImportedCoordinationTerminal>> {
    match target.kind {
        CoordinationTargetKind::AgentAssignment => {
            let mut statement = transaction.prepare(&format!(
                "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
                 WHERE target_session_id=?1 AND kind='result' AND assignment_id=?2
                   AND disposition IN ('pending','materialized')
                 ORDER BY created_at,message_id"
            ))?;
            let messages = statement
                .query_map(params![session_id, target.id], map_message)?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            for message in messages {
                let Ok(payload) = serde_json::from_str::<Value>(&message.content.text) else {
                    continue;
                };
                if payload.get("assignmentId").and_then(Value::as_str) != Some(target.id.as_str()) {
                    continue;
                }
                let Some(status) = payload.get("status").and_then(Value::as_str) else {
                    continue;
                };
                return Ok(Some(ImportedCoordinationTerminal::AgentMessage {
                    evidence: CoordinationTerminalEvidence {
                        target: target.clone(),
                        status: status.to_owned(),
                        evidence_reference: serde_json::json!({
                            "assignmentId":target.id,
                            "agentId":message.source_agent_id,
                            "result":payload.get("result").cloned().unwrap_or(Value::Null),
                            "error":payload.get("error").cloned().unwrap_or(Value::Null),
                        }),
                    },
                    message_id: message.message_id,
                    created_at: message.created_at,
                }));
            }
            Ok(None)
        }
        CoordinationTargetKind::Reply => {
            let mut statement = transaction.prepare(&format!(
                "SELECT {MESSAGE_COLUMNS} FROM agent_message_metadata
                 WHERE target_session_id=?1 AND kind='answer' AND reply_to_message_id=?2
                   AND disposition IN ('pending','materialized')
                 ORDER BY created_at,message_id LIMIT 1"
            ))?;
            Ok(statement
                .query_row(params![session_id, target.id], map_message)
                .optional()?
                .map(|message| ImportedCoordinationTerminal::AgentMessage {
                    evidence: CoordinationTerminalEvidence {
                        target: target.clone(),
                        status: "answered".to_owned(),
                        evidence_reference: serde_json::json!({"messageId":message.message_id}),
                    },
                    message_id: message.message_id,
                    created_at: message.created_at,
                }))
        }
        CoordinationTargetKind::WorkerInvocation => {
            let key = format!("worker-terminal:{}", target.id);
            let record = transaction
                .query_row(
                    "SELECT delivery_id,content,created_at
                     FROM agent_deliveries
                     WHERE target_session_id=?1 AND source_kind='worker_result'
                       AND disposition='pending'
                       AND (result_invocation_id=?2 OR idempotency_key=?3)
                     ORDER BY created_at,delivery_id LIMIT 1",
                    params![session_id, target.id, key],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    },
                )
                .optional()?;
            let Some((delivery_id, content, created_at)) = record else {
                return Ok(None);
            };
            let payload = serde_json::from_str::<Value>(&content).map_err(|error| {
                EventStoreError::InvalidOperation(format!(
                    "worker result delivery '{delivery_id}' has invalid JSON: {error}"
                ))
            })?;
            if payload.get("kind").and_then(Value::as_str) != Some("worker_result")
                || payload.get("invocationId").and_then(Value::as_str) != Some(target.id.as_str())
            {
                return Err(EventStoreError::InvalidOperation(format!(
                    "worker result delivery '{delivery_id}' has inconsistent identity"
                )));
            }
            let status = payload
                .get("status")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "worker result delivery '{delivery_id}' has no terminal status"
                    ))
                })?;
            Ok(Some(ImportedCoordinationTerminal::WorkerDelivery {
                evidence: CoordinationTerminalEvidence {
                    target: target.clone(),
                    status: status.to_owned(),
                    evidence_reference: serde_json::json!({
                        "invocationId":target.id,
                        "status":status,
                        "evidence":payload.get("evidence").cloned().unwrap_or(Value::Null),
                    }),
                },
                delivery_id,
                created_at,
            }))
        }
    }
}

fn apply_coordination_terminal_to_wait_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
    terminal: &CoordinationTerminalEvidence,
    now: &str,
) -> Result<()> {
    let existing = transaction
        .query_row(
            "SELECT disposition,terminal_status,evidence_reference_json
             FROM coordination_wait_members
             WHERE wait_id=?1 AND target_kind=?2 AND target_id=?3",
            params![wait_id, terminal.target.kind.as_str(), terminal.target.id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((disposition, status, _evidence)) = existing else {
        return Err(EventStoreError::InvalidOperation(format!(
            "coordination terminal is not a member of wait '{wait_id}'"
        )));
    };
    match disposition.as_str() {
        "pending" => {
            transaction.execute(
                "UPDATE coordination_wait_members
                 SET disposition='satisfied',terminal_status=?4,
                     evidence_reference_json=?5,resolved_at=?6
                 WHERE wait_id=?1 AND target_kind=?2 AND target_id=?3
                   AND disposition='pending'
                   AND wait_id IN (
                    SELECT wait_id FROM coordination_waits WHERE disposition='pending'
                   )",
                params![
                    wait_id,
                    terminal.target.kind.as_str(),
                    terminal.target.id,
                    terminal.status,
                    serde_json::to_string(&terminal.evidence_reference)?,
                    now,
                ],
            )?;
        }
        "satisfied" if status.as_deref() == Some(terminal.status.as_str()) => {
            // Initial terminal evidence is a cross-store snapshot, not part of
            // wait idempotency. The first committed evidence remains canonical
            // when a replay supplies an equivalent terminal status through a
            // differently shaped owner reference.
        }
        "satisfied" => {
            return Err(EventStoreError::InvalidOperation(format!(
                "coordination terminal evidence conflict for {}:{}",
                terminal.target.kind.as_str(),
                terminal.target.id
            )));
        }
        "released" => {}
        other => {
            return Err(EventStoreError::Internal(format!(
                "unknown coordination wait member disposition '{other}'"
            )));
        }
    }
    Ok(())
}

fn apply_coordination_terminal_globally_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    terminal: &CoordinationTerminalEvidence,
    now: &str,
) -> Result<()> {
    let mut existing_statement = transaction.prepare(
        "SELECT terminal_status,evidence_reference_json
         FROM coordination_wait_members
         WHERE target_kind=?1 AND target_id=?2 AND disposition='satisfied'",
    )?;
    let existing = existing_statement
        .query_map(
            params![terminal.target.kind.as_str(), terminal.target.id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (status, evidence) in existing {
        let evidence = serde_json::from_str::<Value>(&evidence)?;
        if status != terminal.status || evidence != terminal.evidence_reference {
            return Err(EventStoreError::InvalidOperation(format!(
                "coordination terminal evidence conflict for {}:{}",
                terminal.target.kind.as_str(),
                terminal.target.id
            )));
        }
    }
    transaction.execute(
        "UPDATE coordination_wait_members
         SET disposition='satisfied',terminal_status=?3,
             evidence_reference_json=?4,resolved_at=?5
         WHERE target_kind=?1 AND target_id=?2 AND disposition='pending'
           AND wait_id IN (
            SELECT wait_id FROM coordination_waits WHERE disposition='pending'
           )",
        params![
            terminal.target.kind.as_str(),
            terminal.target.id,
            terminal.status,
            serde_json::to_string(&terminal.evidence_reference)?,
            now,
        ],
    )?;
    Ok(())
}

fn resolve_coordination_wait_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
    now: &str,
) -> Result<()> {
    let Some(wait) = query_wait_by_id(transaction, wait_id)? else {
        return Err(EventStoreError::Internal(format!(
            "coordination wait '{wait_id}' disappeared"
        )));
    };
    if wait.disposition != "pending" {
        return Ok(());
    }
    let (pending, satisfied) = transaction.query_row(
        "SELECT
            SUM(CASE WHEN disposition='pending' THEN 1 ELSE 0 END),
            SUM(CASE WHEN disposition='satisfied' THEN 1 ELSE 0 END)
         FROM coordination_wait_members WHERE wait_id=?1",
        [wait_id],
        |row| Ok((row.get::<_, usize>(0)?, row.get::<_, usize>(1)?)),
    )?;
    let ready = match wait.mode {
        CoordinationWaitMode::All => pending == 0,
        CoordinationWaitMode::Any => satisfied > 0,
    };
    if !ready {
        return Ok(());
    }
    if wait.mode == CoordinationWaitMode::Any {
        transaction.execute(
            "UPDATE coordination_wait_members
             SET disposition='released',resolved_at=?2
             WHERE wait_id=?1 AND disposition='pending'",
            params![wait_id, now],
        )?;
    }
    transaction.execute(
        "UPDATE coordination_waits
         SET disposition='satisfied',resolved_at=?2
         WHERE wait_id=?1 AND disposition='pending'",
        params![wait_id, now],
    )?;
    Ok(())
}

fn resolve_all_pending_coordination_waits_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    now: &str,
) -> Result<()> {
    let wait_ids = {
        let mut statement = transaction.prepare(
            "SELECT wait_id FROM coordination_waits
             WHERE disposition='pending' ORDER BY created_at,wait_id",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    for wait_id in wait_ids {
        resolve_coordination_wait_in_tx(transaction, &wait_id, now)?;
    }
    Ok(())
}

fn query_unbound_wait_resolution_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
) -> Result<Option<CoordinationWaitResolution>> {
    let Some(wait) = query_wait_by_id(transaction, wait_id)? else {
        return Ok(None);
    };
    if wait.disposition != "satisfied" || wait.aggregate_message_id.is_some() {
        return Ok(None);
    }
    let consumed_inline = transaction.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM coordination_wait_inline_results WHERE wait_id=?1
         )",
        [wait_id],
        |row| row.get::<_, bool>(0),
    )?;
    if consumed_inline {
        return Ok(None);
    }
    let satisfied = query_wait_members_in_tx(transaction, wait_id)?
        .into_iter()
        .filter(|member| member.disposition == "satisfied")
        .collect();
    Ok(Some(CoordinationWaitResolution { wait, satisfied }))
}

fn wait_member_is_satisfied_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
    target: &CoordinationWaitTarget,
) -> Result<bool> {
    transaction
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM coordination_wait_members
                WHERE wait_id=?1 AND target_kind=?2 AND target_id=?3
                  AND disposition='satisfied'
             )",
            params![wait_id, target.kind.as_str(), target.id],
            |row| row.get(0),
        )
        .map_err(EventStoreError::from)
}

fn absorb_imported_coordination_terminal_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    session_id: &str,
    terminal: &ImportedCoordinationTerminal,
    now: &str,
) -> Result<()> {
    match terminal {
        ImportedCoordinationTerminal::AgentMessage { message_id, .. } => {
            transaction.execute(
                "UPDATE agent_message_metadata
                 SET disposition='cancelled',cancelled_at=?3
                 WHERE message_id=?1 AND target_session_id=?2
                   AND disposition='pending'",
                params![message_id, session_id, now],
            )?;
            transaction.execute(
                "UPDATE agent_message_metadata
                 SET disposition='observed',observed_at=?3
                 WHERE message_id=?1 AND target_session_id=?2
                   AND disposition='materialized'",
                params![message_id, session_id, now],
            )?;
            absorb_delivery_in_tx(
                transaction,
                session_id,
                &format!("agent-message-delivery:{message_id}"),
                now,
            )?;
        }
        ImportedCoordinationTerminal::WorkerDelivery { delivery_id, .. } => {
            absorb_delivery_by_id_in_tx(transaction, session_id, delivery_id, now)?;
        }
    }
    Ok(())
}

fn absorb_delivery_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    session_id: &str,
    idempotency_key: &str,
    now: &str,
) -> Result<()> {
    let delivery_id = transaction
        .query_row(
            "SELECT delivery_id FROM agent_deliveries
             WHERE target_session_id=?1 AND idempotency_key=?2",
            params![session_id, idempotency_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(delivery_id) = delivery_id {
        absorb_delivery_by_id_in_tx(transaction, session_id, &delivery_id, now)?;
    }
    Ok(())
}

fn absorb_delivery_by_id_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    session_id: &str,
    delivery_id: &str,
    now: &str,
) -> Result<()> {
    transaction.execute(
        "UPDATE agent_deliveries
         SET disposition='cancelled',cancelled_at=?3,
             wake_policy='passive',next_wake_at=NULL
         WHERE delivery_id=?1 AND target_session_id=?2
           AND disposition='pending' AND leased_run_id IS NULL",
        params![delivery_id, session_id, now],
    )?;
    transaction.execute(
        "UPDATE agent_deliveries
         SET wake_policy='passive',next_wake_at=NULL
         WHERE delivery_id=?1 AND target_session_id=?2
           AND disposition='pending' AND leased_run_id IS NOT NULL",
        params![delivery_id, session_id],
    )?;
    Ok(())
}

fn persist_coordination_wait_topology_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
    request: &NewCoordinationWait,
) -> Result<()> {
    let now = chrono::Utc::now().to_rfc3339();
    let topology_json = encode_dependency_topology(&request.dependency_edges)?;
    transaction.execute(
        "INSERT OR IGNORE INTO coordination_wait_dependency_topologies(
            wait_id,topology_json,created_at
         ) VALUES (?1,?2,?3)",
        params![wait_id, topology_json, now],
    )?;
    let stored_topology = transaction.query_row(
        "SELECT topology_json FROM coordination_wait_dependency_topologies WHERE wait_id=?1",
        [wait_id],
        |row| row.get::<_, String>(0),
    )?;
    if stored_topology != topology_json {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait topology idempotency conflict".to_owned(),
        ));
    }
    for edge in &request.dependency_edges {
        transaction.execute(
            "INSERT OR IGNORE INTO coordination_dependency_edges(
                source_dependency_id,target_dependency_id,edge_kind,created_at
             ) VALUES (?1,?2,?3,?4)",
            params![
                edge.source_dependency_id,
                edge.target_dependency_id,
                edge.kind.as_str(),
                now,
            ],
        )?;
    }

    let existing_count = transaction.query_row(
        "SELECT COUNT(*) FROM coordination_wait_dependency_nodes WHERE wait_id=?1",
        [wait_id],
        |row| row.get::<_, usize>(0),
    )?;
    if existing_count == 0 {
        transaction.execute(
            "INSERT INTO coordination_wait_dependency_nodes(
                wait_id,endpoint_kind,target_kind,target_id,dependency_id,ordinal
             ) VALUES (?1,'owner','owner',?2,?3,-1)",
            params![wait_id, request.owner_agent_id, request.owner_dependency_id],
        )?;
        for (ordinal, dependency) in request.dependencies.iter().enumerate() {
            transaction.execute(
                "INSERT INTO coordination_wait_dependency_nodes(
                    wait_id,endpoint_kind,target_kind,target_id,dependency_id,ordinal
                 ) VALUES (?1,'member',?2,?3,?4,?5)",
                params![
                    wait_id,
                    dependency.target.kind.as_str(),
                    dependency.target.id,
                    dependency.dependency_id,
                    ordinal,
                ],
            )?;
        }
        return Ok(());
    }

    let owner = transaction
        .query_row(
            "SELECT target_id,dependency_id
             FROM coordination_wait_dependency_nodes
             WHERE wait_id=?1 AND endpoint_kind='owner'",
            [wait_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    if owner.as_ref()
        != Some(&(
            request.owner_agent_id.clone(),
            request.owner_dependency_id.clone(),
        ))
    {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait dependency idempotency conflict".to_owned(),
        ));
    }
    let mut statement = transaction.prepare(
        "SELECT target_kind,target_id,dependency_id
         FROM coordination_wait_dependency_nodes
         WHERE wait_id=?1 AND endpoint_kind='member' ORDER BY ordinal",
    )?;
    let existing = statement
        .query_map([wait_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let requested = request
        .dependencies
        .iter()
        .map(|dependency| {
            (
                dependency.target.kind.as_str().to_owned(),
                dependency.target.id.clone(),
                dependency.dependency_id.clone(),
            )
        })
        .collect::<Vec<_>>();
    if existing != requested {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait dependency idempotency conflict".to_owned(),
        ));
    }
    Ok(())
}

fn encode_dependency_topology(edges: &[CoordinationDependencyEdge]) -> Result<String> {
    let mut canonical = edges.to_vec();
    canonical.sort();
    serde_json::to_string(
        &canonical
            .iter()
            .map(|edge| {
                serde_json::json!({
                    "source":edge.source_dependency_id,
                    "target":edge.target_dependency_id,
                    "kind":edge.kind.as_str(),
                })
            })
            .collect::<Vec<_>>(),
    )
    .map_err(EventStoreError::from)
}

/// Fail closed when an older development profile contains a pending wait that
/// predates normalized dependency custody. Replaying that exact tool call
/// backfills its side-table rows; already-terminal historical waits remain
/// readable and never block new admissions.
fn ensure_pending_wait_topology_complete_in_tx(
    transaction: &rusqlite::Transaction<'_>,
) -> Result<()> {
    let incomplete = transaction.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM coordination_waits wait
            WHERE wait.disposition='pending' AND (
                NOT EXISTS(
                    SELECT 1 FROM coordination_wait_dependency_nodes owner
                    WHERE owner.wait_id=wait.wait_id AND owner.endpoint_kind='owner'
                ) OR NOT EXISTS(
                    SELECT 1 FROM coordination_wait_dependency_topologies topology
                    WHERE topology.wait_id=wait.wait_id
                ) OR EXISTS(
                    SELECT 1 FROM coordination_wait_members member
                    WHERE member.wait_id=wait.wait_id AND member.disposition='pending'
                      AND NOT EXISTS(
                        SELECT 1 FROM coordination_wait_dependency_nodes dependency
                        WHERE dependency.wait_id=member.wait_id
                          AND dependency.endpoint_kind='member'
                          AND dependency.target_kind=member.target_kind
                          AND dependency.target_id=member.target_id
                      )
                )
            )
         )",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    if incomplete {
        return Err(EventStoreError::InvalidOperation(
            "coordination wait dependency topology is incomplete; replay or resolve the retained wait before admitting new dependencies"
                .to_owned(),
        ));
    }
    Ok(())
}

fn coordination_wait_has_cycle_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
) -> Result<bool> {
    let owner_dependency_id = transaction.query_row(
        "SELECT dependency_id FROM coordination_wait_dependency_nodes
         WHERE wait_id=?1 AND endpoint_kind='owner'",
        [wait_id],
        |row| row.get::<_, String>(0),
    )?;
    let mut statement = transaction.prepare(
        "SELECT dependency.dependency_id
         FROM coordination_wait_members member
         JOIN coordination_wait_dependency_nodes dependency
           ON dependency.wait_id=member.wait_id
          AND dependency.endpoint_kind='member'
          AND dependency.target_kind=member.target_kind
          AND dependency.target_id=member.target_id
         WHERE member.wait_id=?1 AND member.disposition='pending'
         ORDER BY member.ordinal",
    )?;
    let targets = statement
        .query_map([wait_id], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for target_dependency_id in targets {
        if dependency_path_exists_in_tx(transaction, &target_dependency_id, &owner_dependency_id)? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn dependency_path_exists_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    source_dependency_id: &str,
    target_dependency_id: &str,
) -> Result<bool> {
    if source_dependency_id == target_dependency_id {
        return Ok(true);
    }
    transaction
        .query_row(
            "WITH RECURSIVE edges(source_id,target_id) AS (
                SELECT source_dependency_id,target_dependency_id
                FROM coordination_dependency_edges
                UNION
                SELECT owner.dependency_id,member_dependency.dependency_id
                FROM coordination_waits wait
                JOIN coordination_wait_dependency_nodes owner
                  ON owner.wait_id=wait.wait_id AND owner.endpoint_kind='owner'
                JOIN coordination_wait_members member
                  ON member.wait_id=wait.wait_id AND member.disposition='pending'
                JOIN coordination_wait_dependency_nodes member_dependency
                  ON member_dependency.wait_id=member.wait_id
                 AND member_dependency.endpoint_kind='member'
                 AND member_dependency.target_kind=member.target_kind
                 AND member_dependency.target_id=member.target_id
                WHERE wait.disposition='pending'
             ), reachable(dependency_id) AS (
                SELECT ?1
                UNION
                SELECT edges.target_id
                FROM edges JOIN reachable ON edges.source_id=reachable.dependency_id
             )
             SELECT EXISTS(
                SELECT 1 FROM reachable WHERE dependency_id=?2
             )",
            params![source_dependency_id, target_dependency_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(EventStoreError::from)
}
