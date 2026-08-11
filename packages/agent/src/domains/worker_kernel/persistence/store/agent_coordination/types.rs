//! Reusable-agent coordination records.
//!
//! These source-owned DTOs and closed enums are shared by the cohesive persistence submodules.

use super::*;

macro_rules! string_enum {
    ($name:ident { $($variant:ident => $value:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
        #[serde(rename_all = "snake_case")]
        pub(crate) enum $name { $($variant),+ }

        impl $name {
            pub(crate) const fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $value),+ }
            }

            pub(super) fn parse(value: &str) -> Option<Self> {
                match value { $($value => Some(Self::$variant),)+ _ => None }
            }
        }
    };
}

macro_rules! string_enum_parse_only {
    ($name:ident { $($variant:ident => $value:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
        #[serde(rename_all = "snake_case")]
        pub(crate) enum $name { $($variant),+ }

        impl $name {
            pub(super) fn parse(value: &str) -> Option<Self> {
                match value { $($value => Some(Self::$variant),)+ _ => None }
            }
        }
    };
}

string_enum!(AgentInstanceKind {
    Root => "root",
    General => "general",
    Role => "role",
    DirectWorker => "direct_worker",
});

string_enum!(AgentVisibility {
    Nested => "nested",
    Visible => "visible",
});

string_enum!(AgentInstanceState {
    Provisioning => "provisioning",
    Idle => "idle",
    Active => "active",
    Waiting => "waiting",
    Closing => "closing",
    Closed => "closed",
});

string_enum!(AgentAssignmentKind {
    Instruction => "instruction",
    Request => "request",
    Operator => "operator",
    DirectWorker => "direct_worker",
});

string_enum!(AgentAssignmentStatus {
    Offered => "offered",
    Accepted => "accepted",
    Queued => "queued",
    Running => "running",
    Waiting => "waiting",
    Completed => "completed",
    Declined => "declined",
    Failed => "failed",
    Cancelled => "cancelled",
    TimedOut => "timed_out",
    Expired => "expired",
});

impl AgentAssignmentStatus {
    pub(crate) const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed
                | Self::Declined
                | Self::Failed
                | Self::Cancelled
                | Self::TimedOut
                | Self::Expired
        )
    }
}

string_enum_parse_only!(ExecutionKind {
    Worker => "worker",
    AgentAssignment => "agent_assignment",
});

string_enum!(AgentOutboxKind {
    Provision => "provision",
    Message => "message",
    Result => "result",
    Projection => "projection",
});

string_enum_parse_only!(AgentOutboxDisposition {
    Pending => "pending",
    Importing => "importing",
    Imported => "imported",
    Rejected => "rejected",
});

string_enum!(AgentManagementCapability {
    Assign => "assign",
    Cancel => "cancel",
    Configure => "configure",
    Close => "close",
});

string_enum!(WorkspaceClaimKind {
    ScopedWrite => "scoped_write",
    WorkspaceProcess => "workspace_process",
});

string_enum!(WorkspaceClaimState {
    Queued => "queued",
    Held => "held",
    Released => "released",
    Cancelled => "cancelled",
});

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentInstanceRecord {
    pub(crate) agent_id: String,
    pub(crate) session_id: String,
    pub(crate) root_session_id: String,
    pub(crate) workspace_id: String,
    pub(crate) spawned_by_agent_id: Option<String>,
    pub(crate) management_owner_agent_id: Option<String>,
    pub(crate) kind: AgentInstanceKind,
    pub(crate) role_id: Option<String>,
    pub(crate) role_version: Option<String>,
    pub(crate) name: String,
    pub(crate) visibility: AgentVisibility,
    pub(crate) state: AgentInstanceState,
    pub(crate) default_model: Option<String>,
    pub(crate) default_reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) write_scopes: Value,
    pub(crate) limits: Value,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) closed_at: Option<String>,
}

/// One stable, count-backed page from the profile agent directory.
#[derive(Clone, Debug)]
pub(crate) struct AgentInstancePage {
    pub(crate) items: Vec<AgentInstanceRecord>,
    pub(crate) total: u64,
}

/// One owner-relative relationship page. Child hierarchy ordering is computed
/// in SQLite so a pagination boundary can never place a descendant before its
/// management parent.
#[derive(Clone, Debug)]
pub(crate) struct AgentRelationPage {
    pub(crate) items: Vec<AgentInstanceRecord>,
    pub(crate) total: u64,
    pub(crate) active: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExecutionNodeRecord {
    pub(crate) execution_id: String,
    pub(crate) kind: ExecutionKind,
    pub(crate) parent_execution_id: Option<String>,
    pub(crate) owner_agent_id: Option<String>,
    pub(crate) root_session_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) causal_depth: u32,
    pub(crate) child_slot: Option<u32>,
    pub(crate) worker_invocation_id: Option<String>,
    pub(crate) assignment_id: Option<String>,
    pub(crate) created_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoordinationTraceStateRecord {
    pub(crate) trace_id: String,
    pub(crate) root_session_id: String,
    pub(crate) paused: bool,
    pub(crate) reason: String,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) paused_at: String,
    pub(crate) resumed_at: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentAssignmentRecord {
    pub(crate) assignment_id: String,
    pub(crate) execution_id: String,
    pub(crate) agent_id: String,
    pub(crate) requester_agent_id: Option<String>,
    pub(crate) delegator_agent_id: Option<String>,
    pub(crate) kind: AgentAssignmentKind,
    pub(crate) status: AgentAssignmentStatus,
    pub(crate) admission_key: String,
    pub(crate) queue_ordinal: u64,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) authority_snapshot: Value,
    pub(crate) resource_snapshot: Value,
    pub(crate) write_scopes_snapshot: Value,
    pub(crate) limits_snapshot: Value,
    pub(crate) retry_of_assignment_id: Option<String>,
    pub(crate) result_id: Option<String>,
    pub(crate) result_reference: Option<Value>,
    pub(crate) error: Option<String>,
    pub(crate) deadline_at: Option<String>,
    pub(crate) created_at: String,
    pub(crate) accepted_at: Option<String>,
    pub(crate) started_at: Option<String>,
    pub(crate) completed_at: Option<String>,
    pub(crate) updated_at: String,
}

/// Reverse-queue-order reusable assignment history with an exact durable total.
#[derive(Clone, Debug)]
pub(crate) struct AgentAssignmentPage {
    pub(crate) items: Vec<AgentAssignmentRecord>,
    pub(crate) total: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentResultRecord {
    pub(crate) result_id: String,
    pub(crate) agent_id: String,
    pub(crate) assignment_id: String,
    pub(crate) reference: Value,
}

#[derive(Clone, Debug)]
pub(crate) struct NewRootAgent {
    pub(crate) session_id: String,
    pub(crate) workspace_id: String,
    pub(crate) name: String,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) limits: Value,
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentAdmission {
    pub(crate) admission_key: String,
    pub(crate) root_session_id: String,
    pub(crate) workspace_id: String,
    pub(crate) spawned_by_agent_id: String,
    pub(crate) management_owner_agent_id: String,
    pub(crate) kind: AgentInstanceKind,
    pub(crate) role_id: Option<String>,
    pub(crate) role_version: Option<String>,
    pub(crate) name: String,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) assignment_kind: AgentAssignmentKind,
    pub(crate) requester_agent_id: Option<String>,
    pub(crate) delegator_agent_id: Option<String>,
    pub(crate) parent_execution_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) causal_depth: u32,
    pub(crate) child_slot: Option<u32>,
    pub(crate) max_active_children: u32,
    /// Effective direct-child ceiling owned by the immediate causal parent.
    /// Zero explicitly forbids child agent and worker executions.
    pub(crate) max_child_executions: u32,
    pub(crate) max_execution_nodes: u32,
    pub(crate) max_causal_depth: u32,
    pub(crate) autonomous_hop: u32,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) resource_snapshot: Value,
    pub(crate) write_scopes: Value,
    pub(crate) limits: Value,
    pub(crate) retry_of_assignment_id: Option<String>,
    pub(crate) deadline_at: Option<String>,
}

/// Admission for an agent-runner worker. Its one assignment reuses the
/// already-admitted worker execution node, so mixed topology, cancellation,
/// budgets, and result custody describe one causal execution rather than an
/// ad-hoc parallel transcript run.
#[derive(Clone, Debug)]
pub(crate) struct NewDirectWorkerAgentAdmission {
    pub(crate) invocation_id: String,
    pub(crate) workspace_path: String,
    pub(crate) max_active_children: u32,
    pub(crate) name: String,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) model: String,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) limits: Value,
    pub(crate) deadline_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentAssignment {
    pub(crate) admission_key: String,
    pub(crate) agent_id: String,
    pub(crate) requester_agent_id: Option<String>,
    pub(crate) delegator_agent_id: Option<String>,
    pub(crate) kind: AgentAssignmentKind,
    pub(crate) offered: bool,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) parent_execution_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) causal_depth: u32,
    pub(crate) child_slot: Option<u32>,
    pub(crate) max_active_children: u32,
    /// Effective direct-child ceiling owned by the immediate causal parent.
    /// Zero explicitly forbids child agent and worker executions.
    pub(crate) max_child_executions: u32,
    pub(crate) max_execution_nodes: u32,
    pub(crate) max_causal_depth: u32,
    pub(crate) max_queued_assignments: u32,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) authority_snapshot: Value,
    pub(crate) resource_snapshot: Value,
    pub(crate) write_scopes_snapshot: Value,
    pub(crate) limits_snapshot: Value,
    pub(crate) retry_of_assignment_id: Option<String>,
    pub(crate) deadline_at: Option<String>,
    pub(crate) message: NewAgentAssignmentMessage,
}

/// Canonical semantic message committed atomically with a newly admitted
/// assignment. The assignment id and target agent are injected by the store.
#[derive(Clone, Debug)]
pub(crate) struct NewAgentAssignmentMessage {
    pub(crate) deduplication_key: String,
    pub(crate) message_id: String,
    pub(crate) channel_id: String,
    pub(crate) source_agent_id: String,
    pub(crate) source_session_id: String,
    pub(crate) source_name: Option<String>,
    pub(crate) target_session_id: String,
    pub(crate) kind: AgentMessageKind,
    pub(crate) authority: AgentMessageAuthority,
    pub(crate) reply_to: Option<String>,
    pub(crate) text: String,
    pub(crate) autonomous_hop: u32,
}

/// One cross-database message effect. The outbox stores a canonical envelope
/// with source/target identities beside the semantic message payload; the
/// EventStore importer is the only code that materializes it into Tron state.
#[derive(Clone, Debug)]
pub(crate) struct NewAgentMessageOutbox {
    pub(crate) deduplication_key: String,
    pub(crate) source_agent_id: String,
    pub(crate) target_agent_id: String,
    pub(crate) assignment_id: Option<String>,
    pub(crate) payload: Value,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentConfigurationUpdate {
    pub(crate) agent_id: String,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) write_scopes: Value,
    pub(crate) limits: Value,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentRoleUpdate {
    pub(crate) agent_id: String,
    pub(crate) role_id: String,
    pub(crate) role_version: String,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) tool_grant: Value,
    pub(crate) limits: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentAdmission {
    pub(crate) agent: AgentInstanceRecord,
    pub(crate) assignment: AgentAssignmentRecord,
    pub(crate) execution: ExecutionNodeRecord,
    pub(crate) created: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentAssignmentTransition {
    pub(crate) assignment_id: String,
    pub(crate) expected_status: AgentAssignmentStatus,
    pub(crate) target_status: AgentAssignmentStatus,
    /// Exact terminal result. The store creates its integrity-bound reference
    /// in the same transaction; callers never manufacture result references.
    pub(crate) result: Option<Value>,
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentAssignmentAttemptRecord {
    pub(crate) attempt_id: String,
    pub(crate) assignment_id: String,
    pub(crate) attempt_number: u32,
    pub(crate) status: String,
    pub(crate) run_id: Option<String>,
    pub(crate) baseline_event_sequence: i64,
    pub(crate) started_at: String,
    pub(crate) completed_at: Option<String>,
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentExecutionEventRecord {
    pub(crate) event_id: String,
    pub(crate) execution_id: String,
    pub(crate) sequence: u64,
    pub(crate) kind: String,
    pub(crate) details: Value,
    pub(crate) occurred_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentOutboxRecord {
    pub(crate) outbox_id: String,
    pub(crate) deduplication_key: String,
    pub(crate) kind: AgentOutboxKind,
    pub(crate) agent_id: Option<String>,
    pub(crate) assignment_id: Option<String>,
    pub(crate) execution_id: Option<String>,
    pub(crate) payload: Value,
    pub(crate) disposition: AgentOutboxDisposition,
    pub(crate) attempts: u32,
    pub(crate) last_error: Option<String>,
    pub(crate) next_attempt_at: String,
    pub(crate) created_at: String,
    pub(crate) processed_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum AgentOutboxRetryOutcome {
    Scheduled {
        attempts: u32,
        next_attempt_at: String,
    },
    Rejected {
        attempts: u32,
        processed_at: String,
    },
}

#[cfg(test)]
#[derive(Clone, Debug)]
pub(crate) struct NewAgentManagementGrant {
    pub(crate) idempotency_key: String,
    pub(crate) target_agent_id: String,
    pub(crate) grantee_agent_id: String,
    pub(crate) granted_by_agent_id: String,
    pub(crate) capability: AgentManagementCapability,
}

#[derive(Clone, Debug)]
pub(crate) struct NewAgentManagementGrantBatch {
    pub(crate) idempotency_key: String,
    pub(crate) target_agent_id: String,
    pub(crate) grantee_agent_id: String,
    pub(crate) granted_by_agent_id: String,
    pub(crate) capabilities: Vec<AgentManagementCapability>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentManagementGrantRecord {
    pub(crate) grant_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) target_agent_id: String,
    pub(crate) grantee_agent_id: String,
    pub(crate) granted_by_agent_id: String,
    pub(crate) capability: AgentManagementCapability,
    pub(crate) created_at: String,
    pub(crate) revoked_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) enum WorkspaceClaimHolder {
    /// One reusable-agent assignment owns the claim through its mixed
    /// execution node and stable agent identity.
    AgentExecution {
        execution_id: String,
        agent_id: String,
    },
    /// An ordinary session invocation owns the claim directly. This gives
    /// visible root sessions and non-assignment engine work durable custody
    /// without manufacturing an assignment or an authority grant.
    Session { session_id: String },
}

#[derive(Clone, Debug)]
pub(crate) struct NewWorkspaceClaim {
    pub(crate) idempotency_key: String,
    pub(crate) holder: WorkspaceClaimHolder,
    pub(crate) workspace_id: String,
    pub(crate) kind: WorkspaceClaimKind,
    /// Canonical, workspace-relative path. `.` is reserved for process claims.
    pub(crate) canonical_scope: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WorkspaceClaimRecord {
    pub(crate) claim_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) execution_id: Option<String>,
    pub(crate) agent_id: Option<String>,
    pub(crate) holder_session_id: Option<String>,
    pub(crate) workspace_id: String,
    pub(crate) kind: WorkspaceClaimKind,
    pub(crate) canonical_scope: String,
    pub(crate) state: WorkspaceClaimState,
    pub(crate) requested_at: String,
    pub(crate) acquired_at: Option<String>,
    pub(crate) released_at: Option<String>,
    /// Positive Unix process-group/direct-child id captured after spawn for a
    /// whole-workspace process lease. It is restart-recovery evidence only.
    pub(crate) process_id: Option<u32>,
    /// OS-reported process birth identity captured with `process_id`. Recovery
    /// must re-read and match it before signalling the process group, so a
    /// recycled numeric PID can never target unrelated local work.
    pub(crate) process_identity: Option<String>,
}

/// Count-backed resource-claim page used by bounded Team Context projection.
#[derive(Clone, Debug)]
pub(crate) struct WorkspaceClaimPage {
    pub(crate) items: Vec<WorkspaceClaimRecord>,
    pub(crate) total: u64,
}
