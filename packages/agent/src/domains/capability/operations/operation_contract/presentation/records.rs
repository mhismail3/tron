//! Record-plane provider-visible presentation literals.

use super::OperationPresentation;

const fn presented(display_name: &'static str, description: &'static str) -> OperationPresentation {
    OperationPresentation {
        display_name,
        description,
    }
}

pub(super) const GOAL_CREATE: OperationPresentation = presented(
    "Create Goal",
    "Create a durable scoped goal with lifecycle and evidence references.",
);
pub(super) const GOAL_LIST: OperationPresentation = presented(
    "List Goals",
    "List scoped goals with bounded lifecycle summaries and navigation references.",
);
pub(super) const GOAL_INSPECT: OperationPresentation = presented(
    "Inspect Goal",
    "Inspect one scoped goal and its current lifecycle evidence.",
);
pub(super) const GOAL_CANCEL: OperationPresentation = presented(
    "Cancel Goal",
    "Cancel one nonterminal goal after freshness and idempotency checks.",
);
pub(super) const QUESTION_CREATE: OperationPresentation = presented(
    "Ask User Question",
    "Create a durable scoped question with answer choices and expiry metadata.",
);
pub(super) const QUESTION_LIST: OperationPresentation = presented(
    "List User Questions",
    "List scoped questions with bounded state and answer-navigation summaries.",
);
pub(super) const QUESTION_INSPECT: OperationPresentation = presented(
    "Inspect User Question",
    "Inspect one scoped question and its current answer state.",
);
pub(super) const QUESTION_ANSWER: OperationPresentation = presented(
    "Record User Answer",
    "Record an idempotent answer handoff for one pending question.",
);
pub(super) const MEMORY_STATUS: OperationPresentation = presented(
    "Inspect Memory Status",
    "Inspect current memory policy, engine identity, and prompt-inclusion state.",
);
pub(super) const MEMORY_LIST: OperationPresentation = presented(
    "List Memory Records",
    "List redacted memory records for the current session.",
);
pub(super) const MEMORY_INSPECT: OperationPresentation = presented(
    "Inspect Memory Record",
    "Inspect one redacted memory record and its version history.",
);
pub(super) const MEMORY_QUERY_LIST: OperationPresentation = presented(
    "List Memory Queries",
    "List redacted memory-query evidence and ranked record references.",
);
pub(super) const MEMORY_QUERY_INSPECT: OperationPresentation = presented(
    "Inspect Memory Query",
    "Inspect one redacted memory-query result and its retrieval evidence.",
);
pub(super) const MEMORY_DECISION_LIST: OperationPresentation = presented(
    "List Memory Decisions",
    "List memory inclusion decisions with bounded policy evidence.",
);
pub(super) const MEMORY_DECISION_INSPECT: OperationPresentation = presented(
    "Inspect Memory Decision",
    "Inspect one memory inclusion decision and its policy evidence.",
);
pub(super) const CONTEXT_CONTROL_STATUS: OperationPresentation = presented(
    "Inspect Context Status",
    "Inspect current context composition, token estimates, references, and freshness.",
);
pub(super) const CONTEXT_CONTROL_SNAPSHOT: OperationPresentation = presented(
    "Snapshot Context",
    "Record a provider-safe snapshot of the current session context.",
);
pub(super) const CONTEXT_CONTROL_COMPACT: OperationPresentation = presented(
    "Compact Context",
    "Record and apply a bounded context-compaction boundary without deleting history.",
);
pub(super) const CONTEXT_CONTROL_CLEAR: OperationPresentation = presented(
    "Clear Active Context",
    "Start a new context epoch while preserving inspectable history and evidence.",
);
pub(super) const CONTEXT_CONTROL_ACTION_LIST: OperationPresentation = presented(
    "List Context Actions",
    "List provider-safe summaries of context-control actions in the current session.",
);
pub(super) const CONTEXT_CONTROL_ACTION_INSPECT: OperationPresentation = presented(
    "Inspect Context Action",
    "Inspect one context-control action and its preflight and result evidence.",
);
pub(super) const CONTEXT_SURVIVOR_RECORD: OperationPresentation = presented(
    "Preserve Context Reference",
    "Record a safe reference that future context compaction must preserve.",
);
pub(super) const CONTEXT_SURVIVOR_LIST: OperationPresentation = presented(
    "List Preserved Context",
    "List active safe references that future context compaction must preserve.",
);
pub(super) const CONTEXT_SURVIVOR_DISABLE: OperationPresentation = presented(
    "Stop Preserving Context",
    "Disable one active preserved-context policy after freshness checks.",
);
pub(super) const CONTEXT_EXCLUSION_RECORD: OperationPresentation = presented(
    "Exclude Context Reference",
    "Record a safe reference that future provider context must omit.",
);
pub(super) const CONTEXT_EXCLUSION_LIST: OperationPresentation = presented(
    "List Excluded Context",
    "List active safe references that future provider context must omit.",
);
pub(super) const CONTEXT_EXCLUSION_DISABLE: OperationPresentation = presented(
    "Stop Excluding Context",
    "Disable one active context-exclusion policy after freshness checks.",
);
pub(super) const CONTEXT_POLICY_SNAPSHOT: OperationPresentation = presented(
    "Snapshot Context Policy",
    "Record the complete bounded set of active context inclusion and exclusion policies.",
);
pub(super) const MEDIA_CREATE: OperationPresentation = presented(
    "Create Media Artifact",
    "Create metadata and storage references for a scoped media artifact.",
);
pub(super) const MEDIA_LIST: OperationPresentation = presented(
    "List Media Artifacts",
    "List scoped media artifacts with bounded storage and transcription summaries.",
);
pub(super) const MEDIA_INSPECT: OperationPresentation = presented(
    "Inspect Media Artifact",
    "Inspect one media artifact's metadata, storage, lifecycle, and transcription state.",
);
pub(super) const MEDIA_ARCHIVE: OperationPresentation = presented(
    "Archive Media Artifact",
    "Archive one media artifact while preserving its lifecycle evidence.",
);
pub(super) const IMPORT_HISTORY_RECORD: OperationPresentation = presented(
    "Record Import History",
    "Record bounded lineage between imported session or resource references.",
);
pub(super) const IMPORT_HISTORY_LIST: OperationPresentation = presented(
    "List Import History",
    "List scoped import-lineage records as bounded graph summaries.",
);
pub(super) const IMPORT_HISTORY_INSPECT: OperationPresentation = presented(
    "Inspect Import History",
    "Inspect one import-lineage record and its evidence references.",
);
pub(super) const IMPORT_PREVIEW_RECORD: OperationPresentation = presented(
    "Record Import Preview",
    "Record a content-free preview linking import history and repository metadata.",
);
pub(super) const IMPORT_PREVIEW_LIST: OperationPresentation = presented(
    "List Import Previews",
    "List content-free import previews with bounded counts and path summaries.",
);
pub(super) const IMPORT_PREVIEW_INSPECT: OperationPresentation = presented(
    "Inspect Import Preview",
    "Inspect one content-free import preview and its linked evidence.",
);
pub(super) const PROGRAM_EXECUTION_RECORD: OperationPresentation = presented(
    "Record Program Execution",
    "Record content-free program execution metadata without launching a runtime.",
);
pub(super) const PROGRAM_EXECUTION_LIST: OperationPresentation = presented(
    "List Program Executions",
    "List content-free program execution records and lifecycle summaries.",
);
pub(super) const PROGRAM_EXECUTION_INSPECT: OperationPresentation = presented(
    "Inspect Program Execution",
    "Inspect one content-free program execution record and its evidence.",
);
pub(super) const PROMPT_ARTIFACT_RECORD: OperationPresentation = presented(
    "Record Prompt Artifact",
    "Record opt-in prompt artifact metadata without storing the raw prompt body.",
);
pub(super) const PROMPT_ARTIFACT_LIST: OperationPresentation = presented(
    "List Prompt Artifacts",
    "List opt-in prompt artifacts with bounded metadata and retention state.",
);
pub(super) const PROMPT_ARTIFACT_INSPECT: OperationPresentation = presented(
    "Inspect Prompt Artifact",
    "Inspect one prompt artifact's metadata, references, and retention evidence.",
);
pub(super) const UPDATE_DIAGNOSTIC_RECORD: OperationPresentation = presented(
    "Record Update Diagnostic",
    "Record signed-release and update-check metadata without installing an update.",
);
pub(super) const UPDATE_DIAGNOSTIC_LIST: OperationPresentation = presented(
    "List Update Diagnostics",
    "List bounded update diagnostics and signature status summaries.",
);
pub(super) const UPDATE_DIAGNOSTIC_INSPECT: OperationPresentation = presented(
    "Inspect Update Diagnostic",
    "Inspect one update diagnostic and its provenance and signature evidence.",
);
pub(super) const DEVICE_LIST: OperationPresentation = presented(
    "List Devices",
    "List registered devices with bounded delivery and lifecycle metadata.",
);
pub(super) const DEVICE_INSPECT: OperationPresentation = presented(
    "Inspect Device",
    "Inspect one registered device and its current delivery metadata.",
);
pub(super) const NOTIFICATION_SEND: OperationPresentation = presented(
    "Send Notification",
    "Send one scoped notification through the registered delivery path.",
);
pub(super) const NOTIFICATION_LIST: OperationPresentation = presented(
    "List Notifications",
    "List scoped notifications with bounded delivery and read-state summaries.",
);
pub(super) const NOTIFICATION_INSPECT: OperationPresentation = presented(
    "Inspect Notification",
    "Inspect one notification's content metadata, delivery, and read state.",
);
pub(super) const NOTIFICATION_MARK_READ: OperationPresentation = presented(
    "Mark Notification Read",
    "Mark one scoped notification as read after freshness checks.",
);
pub(super) const NOTIFICATION_MARK_ALL_READ: OperationPresentation = presented(
    "Mark All Notifications Read",
    "Mark all eligible notifications in the current scope as read.",
);
pub(super) const WEB_RESEARCH_REQUEST_RECORD: OperationPresentation = presented(
    "Record Web Research Request",
    "Record bounded web research intent and policy metadata without fetching sources.",
);
pub(super) const WEB_RESEARCH_REQUEST_LIST: OperationPresentation = presented(
    "List Web Research Requests",
    "List scoped web research requests without network or browser activity.",
);
pub(super) const WEB_RESEARCH_REQUEST_INSPECT: OperationPresentation = presented(
    "Inspect Web Research Request",
    "Inspect one web research request and its bounded policy references.",
);
pub(super) const WEB_RESEARCH_REVIEW_RECORD: OperationPresentation = presented(
    "Record Web Research Review",
    "Record a bounded review linked to one web research request.",
);
pub(super) const WEB_RESEARCH_REVIEW_LIST: OperationPresentation = presented(
    "List Web Research Reviews",
    "List scoped web research reviews without network access.",
);
pub(super) const WEB_RESEARCH_REVIEW_INSPECT: OperationPresentation = presented(
    "Inspect Web Research Review",
    "Inspect one web research review and its evidence references.",
);
pub(super) const WEB_RESEARCH_SOURCE_RECORD: OperationPresentation = presented(
    "Record Web Research Source",
    "Record bounded citation metadata linked to a research request or review.",
);
pub(super) const WEB_RESEARCH_SOURCE_LIST: OperationPresentation = presented(
    "List Web Research Sources",
    "List bounded citation artifacts linked to scoped web research.",
);
pub(super) const WEB_RESEARCH_SOURCE_INSPECT: OperationPresentation = presented(
    "Inspect Web Research Source",
    "Inspect one bounded research source and its citation references.",
);
