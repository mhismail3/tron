//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database implementation types stay private to this module. Callers use
//! [`WorkerStore`]. `snapshot` owns verified compressed profile backup and
//! offline restoration before an on-disk worker schema changes.
//!
//! ## Ownership
//!
//! - `filesystem` owns the one canonical atomic-JSON and immutable-tree hash
//!   implementation used by publication and reconstruction.
//! - `rebuild` projects canonical bundles into disposable SQLite indexes.
//! - `snapshot` creates, verifies, and restores owner-only profile archives.
//!   Schema-open callers request those archives only for migrations that
//!   rewrite or remove durable data; additive transactional DDL stays on the
//!   bounded database-open path.
//! - `store` owns canonical publication plus durable invocation, attempt,
//!   generic run-stage evidence, historical result/Attention records, trigger,
//!   health, audit ledgers, and the immutable worker-to-agent outbox.
//!   Run-stage rows are append-only observations attached to the invocation
//!   state machine, not a second job or execution owner. Nested worker calls
//!   retain a parent/per-tool occurrence slot so restart reconstruction replays
//!   one existing child even if a provider regenerates its transient call id
//!   or valid arguments. Its concern modules and scenario tests live beside
//!   that single state owner. Current Attention is a derived view of unresolved
//!   error evidence; informational outcomes remain immutable result history.
//!   Terminal state and delivery effects enter the outbox in the same worker
//!   transaction. Import releases `workers.sqlite` before changing
//!   `tron.sqlite`, then acknowledges only after the Tron commit.
//! - `store::agent_coordination` owns stable agent identities, reusable FIFO
//!   assignments, the mixed agent/worker execution topology, attempts/events,
//!   exact assignment-result custody, bounded management grants, canonical
//!   workspace claims, and the idempotent cross-store coordination outbox.
//!   Its private concern modules separate schema installation, identity and
//!   assignment admission, count-backed directories, dispatch selection,
//!   lifecycle, transition/result custody, outbox recovery, management grants,
//!   claims, canonical row decoding, and shared invariants while extending the
//!   same `WorkerStore` and transaction boundary.
//!   Lifecycle cancellation reads management-owned subtrees without a page
//!   cap and interrupts every matching running attempt in one writer
//!   transaction, retaining an `attempt_finished` execution event per repair.
//!   Exact root-to-execution ancestry is read through one bounded connection
//!   path for cross-store wait normalization; loops, missing parents, and paths
//!   beyond the mixed graph ceiling fail closed before EventStore admission.
//!   Persisted trace pauses retain mixed queued work and outbox evidence while
//!   keeping both schedulers quiescent until authenticated operator resume.
//!   Outbox claims retain their next-attempt timestamp and bounded failure
//!   evidence across restart; due-only selection plus capped exponential
//!   retry prevents one terminally rejected poison effect from starving later
//!   coordination work.
//!   Claims admit either an exact agent execution or a durable session holder;
//!   root sessions never need a fabricated assignment/grant. Conflicting
//!   claims preserve queue order, whole-workspace process claims block later
//!   writers, and a pre-exec gate keeps user code behind the durable PID/birth
//!   identity commit. Startup closes unbound gates and cancels process-local
//!   orphan custody only after ruling out numeric PID reuse.
//!   Stable transcript sessions remain EventStore-owned; neither database is
//!   mutated while holding a transaction in the other.
//! - `store::role_review` owns immutable reviewer proposals and their explicit
//!   apply/reject lifecycle. Each proposal pins target/reviewer versions and
//!   the exact reviewer invocation; restart returns an interrupted apply claim
//!   to proposed without altering canonical worker files.

mod filesystem;
mod rebuild;
mod snapshot;
mod store;

#[allow(unused_imports)]
pub(in crate::domains::worker_kernel) use store::{
    AGENT_ROLE_REVIEW_SCHEMA_VERSION, AgentAdmission, AgentAssignmentAttemptRecord,
    AgentAssignmentKind, AgentAssignmentPage, AgentAssignmentRecord, AgentAssignmentStatus,
    AgentAssignmentTransition, AgentConfigurationUpdate, AgentDeliveryOutboxRecord,
    AgentExecutionEventRecord, AgentInstanceKind, AgentInstancePage, AgentInstanceRecord,
    AgentInstanceState, AgentManagementCapability, AgentManagementGrantRecord, AgentOutboxKind,
    AgentOutboxRecord, AgentOutboxRetryOutcome, AgentRelationPage, AgentResultRecord,
    AgentRoleReviewProposalPage, AgentRoleReviewProposalRecord, AgentRoleReviewStatus,
    AgentRoleUpdate, AgentVisibility, CoordinationTraceStateRecord, ExecutionNodeRecord,
    NewAgentAdmission, NewAgentAssignment, NewAgentAssignmentMessage, NewAgentManagementGrantBatch,
    NewAgentMessageOutbox, NewAgentRoleReviewProposal, NewDirectWorkerAgentAdmission, NewRootAgent,
    NewWorkspaceClaim, NotificationDispatchOutcome, NotificationRefreshDispatch,
    NotificationTargetDispatch, SessionOrganizationDispatch, WorkerStore, WorkspaceClaimHolder,
    WorkspaceClaimKind, WorkspaceClaimPage, WorkspaceClaimRecord, WorkspaceClaimState,
};

pub(crate) use snapshot::{
    ProfileSnapshot, create_profile_snapshot, ensure_worker_schema_snapshot,
    list_profile_snapshots, restore_profile_snapshot, verify_profile_snapshot,
};
