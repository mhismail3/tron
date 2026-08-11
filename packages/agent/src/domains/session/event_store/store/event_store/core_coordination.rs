//! `tron.sqlite` persistence for core reusable-agent coordination.
//!
//! The Agent domain owns semantics; this module owns transactional storage.
//! Assignment IDs are the causal work graph, result/wait/wake reconciliation
//! never crosses a database boundary, and hidden transcript creation commits
//! with child identity plus its first assignment.

use std::collections::{BTreeSet, HashSet};
use std::io;

use rusqlite::{OptionalExtension, params};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::domains::agent::coordination::{
    AgentAdmission, AgentDefaults, AgentDiscoveryQuery, AgentInspection, AgentLifecycle,
    AgentMessageAuditRecord, AgentMessagePage, AgentPage, AgentRecord, AgentRelationship,
    AgentResultRecord, AgentRuntimeStatus, AgentSummary, AgentVisibility, AssignmentAttemptRecord,
    AssignmentKind, AssignmentLimits, AssignmentPage, AssignmentRecord, AssignmentStatus,
    CancelOutcome, CancelRequest, CancelTarget, ClaimAssignment, ClaimedAssignment, CloseAgent,
    CompleteAssignment, ConfigureAgent, CoordinationTraceRecord, EnsureRootAgent,
    HARD_MAX_QUEUED_ASSIGNMENTS, HARD_MAX_TURNS, HARD_TIMEOUT_SECONDS, MAX_AUTONOMOUS_WAKE_HOPS,
    MAX_COORDINATION_MESSAGES, MessageAdmission, MessageKind, NewAssignment, PromoteAgent,
    RegisterWait, RespondToOffer, RetryAssignment, SendMessage, SpawnAgent, WaitAdmission,
    WaitMode, WaitTarget, WakeIntentRecord,
};
use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::sqlite::repositories::blob::BlobRepo;
use crate::domains::session::event_store::sqlite::repositories::session::SessionRepo;
use crate::domains::session::event_store::sqlite::row_types::AGENT_SESSION_TAG;
use crate::shared::protocol::messages::{
    AgentMessageAuthority, AgentMessageContent, AgentMessageKind,
};

use super::EventStore;
use super::coordination::{
    CoordinationDependencyEdge, CoordinationDependencyEdgeKind, CoordinationTargetKind,
    CoordinationWaitDependency, CoordinationWaitMode, CoordinationWaitTarget,
    NewAgentMessageMetadata, NewCoordinationWait, canonical_agent_channel_id,
    create_coordination_wait_in_tx, reconcile_core_assignment_terminal_in_tx,
    record_agent_message_in_tx,
};
use super::session_lifecycle::{CreateSessionInTxOptions, create_session_in_tx};

const INLINE_RESULT_BYTES: usize = 8 * 1024;
const MAX_ID_BYTES: usize = 256;
const MAX_NAME_BYTES: usize = 160;
const MAX_TASK_BYTES: usize = 40_000;
const MAX_CONTEXT_BYTES: usize = 1_048_576;
const MAX_MESSAGE_BYTES: usize = 40_000;
const MAX_WRITE_SCOPES: usize = 64;

const AGENT_COLUMNS: &str = "
    agent_id,transcript_session_id,root_agent_id,workspace_id,parent_agent_id,
    management_owner_agent_id,name,visibility,lifecycle,default_model,
    default_reasoning_level,default_capability_grant_json,default_write_scopes_json,
    default_limits_json,created_at,updated_at,closed_at
";
const ASSIGNMENT_COLUMNS: &str = "
    assignment_id,admission_key,agent_id,requested_by_agent_id,parent_assignment_id,
    retry_of_assignment_id,kind,status,queue_ordinal,trace_id,autonomous_hop,causal_depth,
    causal_ordinal,task,context_json,model,reasoning_level,capability_snapshot_json,
    write_scopes_snapshot_json,limits_snapshot_json,deadline_at,created_at,
    accepted_at,started_at,completed_at,updated_at
";
const ATTEMPT_COLUMNS: &str = "
    attempt_id,assignment_id,attempt_number,status,run_id,baseline_event_sequence,
    started_at,completed_at,error
";
const WAKE_COLUMNS: &str = "
    wake_id,idempotency_key,target_agent_id,target_session_id,target_assignment_id,
    cause_kind,cause_id,trace_id,autonomous_hop,materialized_message_id,
    priority,disposition,not_before,lease_id,delivered_by_lease_id,lease_count,last_error,
    created_at,leased_at,delivered_at,cancelled_at
";

#[derive(Debug)]
struct StoredResult {
    result_id: String,
    assignment_id: String,
    terminal_status: AssignmentStatus,
    inline_json: Option<String>,
    payload_blob_id: Option<String>,
    payload_sha256: Option<String>,
    payload_byte_count: u64,
    error: Option<String>,
    created_at: String,
}

mod assignments;
mod identity;
mod management;
mod messages;
mod persistence;
mod queries;
mod trace;
mod validation;
mod wait_support;
mod waits;

use persistence::*;
use trace::*;
use validation::*;
use wait_support::*;
