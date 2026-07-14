//! Canonical provider-visible presentation metadata for execute operations.
//!
//! This module is the single facade from a canonical OperationId to the
//! friendly display name and concise behavior summary consumed by capability
//! cockpit projections. Literal ownership follows the four established input-
//! schema families, while canonical operation identity remains owned only by
//! operation_contract::OperationId.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | direct | Presentation literals for direct engine and adapter operations |
//! | records | Presentation literals for record-plane operations |
//! | governance | Presentation literals for governance and supervised-runtime operations |
//! | capability_binding | Presentation literals for capability-binding and route operations |
//! | tests | Frozen provider-visible oracle, schema-family parity, style, and unknown-operation coverage |
//!
//! # Invariants
//!
//! - operation_presentation retains the crate-visible facade and returns
//!   None when OperationId::parse rejects an unknown operation.
//! - presentation_entry is the only family-selection point. Its exhaustive
//!   match has no wildcard, so adding an operation requires explicit metadata.
//! - Child modules are private and their constants are visible only to this
//!   parent; they do not own or repeat canonical operation strings.
//! - Display names and descriptions are provider/native-visible contract bytes
//!   frozen by an independently reviewed ordered oracle.

use super::OperationId;

mod capability_binding;
mod direct;
mod governance;
mod records;

#[cfg(test)]
mod tests;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OperationPresentation {
    pub(crate) display_name: &'static str,
    pub(crate) description: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PresentationEntry {
    presentation: OperationPresentation,
    #[cfg(test)]
    family: PresentationFamily,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PresentationFamily {
    Direct,
    Records,
    Governance,
    CapabilityBinding,
}

#[cfg(test)]
impl PresentationFamily {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Records => "records",
            Self::Governance => "governance",
            Self::CapabilityBinding => "capability_binding",
        }
    }
}

pub(crate) fn operation_presentation(operation: &str) -> Option<OperationPresentation> {
    OperationId::parse(operation).map(presentation)
}

fn presentation(operation: OperationId) -> OperationPresentation {
    presentation_entry(operation).presentation
}

#[cfg(test)]
fn presentation_family(operation: OperationId) -> PresentationFamily {
    presentation_entry(operation).family
}

const fn presentation_entry(operation: OperationId) -> PresentationEntry {
    match operation {
        OperationId::Observe => direct::OBSERVE,
        OperationId::StateGet => direct::STATE_GET,
        OperationId::StateSet => direct::STATE_SET,
        OperationId::StateList => direct::STATE_LIST,
        OperationId::FilesystemRead => direct::FILESYSTEM_READ,
        OperationId::FilesystemList => direct::FILESYSTEM_LIST,
        OperationId::FilesystemFind => direct::FILESYSTEM_FIND,
        OperationId::FilesystemGlob => direct::FILESYSTEM_GLOB,
        OperationId::FilesystemSearchText => direct::FILESYSTEM_SEARCH_TEXT,
        OperationId::FilesystemDiff => direct::FILESYSTEM_DIFF,
        OperationId::FilesystemWrite => direct::FILESYSTEM_WRITE,
        OperationId::FilesystemEdit => direct::FILESYSTEM_EDIT,
        OperationId::FilesystemApplyPatch => direct::FILESYSTEM_APPLY_PATCH,
        OperationId::GitStatus => direct::GIT_STATUS,
        OperationId::GitDiff => direct::GIT_DIFF,
        OperationId::GitBranchInventory => direct::GIT_BRANCH_INVENTORY,
        OperationId::GitStage => direct::GIT_STAGE,
        OperationId::GitUnstage => direct::GIT_UNSTAGE,
        OperationId::GitCommit => direct::GIT_COMMIT,
        OperationId::GitBranchStart => direct::GIT_BRANCH_START,
        OperationId::ProcessRun => direct::PROCESS_RUN,
        OperationId::JobStart => direct::JOB_START,
        OperationId::JobStatus => direct::JOB_STATUS,
        OperationId::JobList => direct::JOB_LIST,
        OperationId::JobLog => direct::JOB_LOG,
        OperationId::JobCancel => direct::JOB_CANCEL,
        OperationId::GoalCreate => records::GOAL_CREATE,
        OperationId::GoalList => records::GOAL_LIST,
        OperationId::GoalInspect => records::GOAL_INSPECT,
        OperationId::GoalCancel => records::GOAL_CANCEL,
        OperationId::QuestionCreate => records::QUESTION_CREATE,
        OperationId::QuestionList => records::QUESTION_LIST,
        OperationId::QuestionInspect => records::QUESTION_INSPECT,
        OperationId::QuestionAnswer => records::QUESTION_ANSWER,
        OperationId::TraceList => direct::TRACE_LIST,
        OperationId::TraceGet => direct::TRACE_GET,
        OperationId::LogRecent => direct::LOG_RECENT,
        OperationId::ReplayManifest => direct::REPLAY_MANIFEST,
        OperationId::CatalogSearch => direct::CATALOG_SEARCH,
        OperationId::CatalogInspect => direct::CATALOG_INSPECT,
        OperationId::CatalogConformance => direct::CATALOG_CONFORMANCE,
        OperationId::MemoryStatus => records::MEMORY_STATUS,
        OperationId::MemoryList => records::MEMORY_LIST,
        OperationId::MemoryInspect => records::MEMORY_INSPECT,
        OperationId::MemoryQueryList => records::MEMORY_QUERY_LIST,
        OperationId::MemoryQueryInspect => records::MEMORY_QUERY_INSPECT,
        OperationId::MemoryDecisionList => records::MEMORY_DECISION_LIST,
        OperationId::MemoryDecisionInspect => records::MEMORY_DECISION_INSPECT,
        OperationId::ContextControlStatus => records::CONTEXT_CONTROL_STATUS,
        OperationId::ContextControlSnapshot => records::CONTEXT_CONTROL_SNAPSHOT,
        OperationId::ContextControlCompact => records::CONTEXT_CONTROL_COMPACT,
        OperationId::ContextControlClear => records::CONTEXT_CONTROL_CLEAR,
        OperationId::ContextControlActionList => records::CONTEXT_CONTROL_ACTION_LIST,
        OperationId::ContextControlActionInspect => records::CONTEXT_CONTROL_ACTION_INSPECT,
        OperationId::ContextSurvivorRecord => records::CONTEXT_SURVIVOR_RECORD,
        OperationId::ContextSurvivorList => records::CONTEXT_SURVIVOR_LIST,
        OperationId::ContextSurvivorDisable => records::CONTEXT_SURVIVOR_DISABLE,
        OperationId::ContextExclusionRecord => records::CONTEXT_EXCLUSION_RECORD,
        OperationId::ContextExclusionList => records::CONTEXT_EXCLUSION_LIST,
        OperationId::ContextExclusionDisable => records::CONTEXT_EXCLUSION_DISABLE,
        OperationId::ContextPolicySnapshot => records::CONTEXT_POLICY_SNAPSHOT,
        OperationId::MediaCreate => records::MEDIA_CREATE,
        OperationId::MediaList => records::MEDIA_LIST,
        OperationId::MediaInspect => records::MEDIA_INSPECT,
        OperationId::MediaArchive => records::MEDIA_ARCHIVE,
        OperationId::ImportHistoryRecord => records::IMPORT_HISTORY_RECORD,
        OperationId::ImportHistoryList => records::IMPORT_HISTORY_LIST,
        OperationId::ImportHistoryInspect => records::IMPORT_HISTORY_INSPECT,
        OperationId::RepositoryTreeSnapshot => direct::REPOSITORY_TREE_SNAPSHOT,
        OperationId::RepositoryTreeList => direct::REPOSITORY_TREE_LIST,
        OperationId::RepositoryTreeInspect => direct::REPOSITORY_TREE_INSPECT,
        OperationId::ImportPreviewRecord => records::IMPORT_PREVIEW_RECORD,
        OperationId::ImportPreviewList => records::IMPORT_PREVIEW_LIST,
        OperationId::ImportPreviewInspect => records::IMPORT_PREVIEW_INSPECT,
        OperationId::ProgramExecutionRecord => records::PROGRAM_EXECUTION_RECORD,
        OperationId::ProgramExecutionList => records::PROGRAM_EXECUTION_LIST,
        OperationId::ProgramExecutionInspect => records::PROGRAM_EXECUTION_INSPECT,
        OperationId::PromptArtifactRecord => records::PROMPT_ARTIFACT_RECORD,
        OperationId::PromptArtifactList => records::PROMPT_ARTIFACT_LIST,
        OperationId::PromptArtifactInspect => records::PROMPT_ARTIFACT_INSPECT,
        OperationId::UpdateDiagnosticRecord => records::UPDATE_DIAGNOSTIC_RECORD,
        OperationId::UpdateDiagnosticList => records::UPDATE_DIAGNOSTIC_LIST,
        OperationId::UpdateDiagnosticInspect => records::UPDATE_DIAGNOSTIC_INSPECT,
        OperationId::DeviceList => records::DEVICE_LIST,
        OperationId::DeviceInspect => records::DEVICE_INSPECT,
        OperationId::NotificationSend => records::NOTIFICATION_SEND,
        OperationId::NotificationList => records::NOTIFICATION_LIST,
        OperationId::NotificationInspect => records::NOTIFICATION_INSPECT,
        OperationId::NotificationMarkRead => records::NOTIFICATION_MARK_READ,
        OperationId::NotificationMarkAllRead => records::NOTIFICATION_MARK_ALL_READ,
        OperationId::ProceduralDefinitionRecord => governance::PROCEDURAL_DEFINITION_RECORD,
        OperationId::ProceduralStateList => governance::PROCEDURAL_STATE_LIST,
        OperationId::ProceduralStateInspect => governance::PROCEDURAL_STATE_INSPECT,
        OperationId::ProceduralActivationRequestRecord => {
            governance::PROCEDURAL_ACTIVATION_REQUEST_RECORD
        }
        OperationId::ProceduralActivationRequestList => {
            governance::PROCEDURAL_ACTIVATION_REQUEST_LIST
        }
        OperationId::ProceduralActivationRequestInspect => {
            governance::PROCEDURAL_ACTIVATION_REQUEST_INSPECT
        }
        OperationId::ProceduralActivationDecisionRecord => {
            governance::PROCEDURAL_ACTIVATION_DECISION_RECORD
        }
        OperationId::ProceduralActivationDecisionList => {
            governance::PROCEDURAL_ACTIVATION_DECISION_LIST
        }
        OperationId::ProceduralActivationDecisionInspect => {
            governance::PROCEDURAL_ACTIVATION_DECISION_INSPECT
        }
        OperationId::ScheduleCreate => governance::SCHEDULE_CREATE,
        OperationId::ScheduleList => governance::SCHEDULE_LIST,
        OperationId::ScheduleInspect => governance::SCHEDULE_INSPECT,
        OperationId::ScheduleCancel => governance::SCHEDULE_CANCEL,
        OperationId::ScheduleFireDue => governance::SCHEDULE_FIRE_DUE,
        OperationId::ToolSourceList => governance::TOOL_SOURCE_LIST,
        OperationId::ToolSourceInspect => governance::TOOL_SOURCE_INSPECT,
        OperationId::SubagentLaunch => governance::SUBAGENT_LAUNCH,
        OperationId::SubagentStatus => governance::SUBAGENT_STATUS,
        OperationId::SubagentResult => governance::SUBAGENT_RESULT,
        OperationId::SubagentCancel => governance::SUBAGENT_CANCEL,
        OperationId::SubagentTaskList => governance::SUBAGENT_TASK_LIST,
        OperationId::SubagentTaskInspect => governance::SUBAGENT_TASK_INSPECT,
        OperationId::WorkerPackageList => governance::WORKER_PACKAGE_LIST,
        OperationId::WorkerPackageInspect => governance::WORKER_PACKAGE_INSPECT,
        OperationId::ModuleList => governance::MODULE_LIST,
        OperationId::ModuleInspect => governance::MODULE_INSPECT,
        OperationId::ModuleProposalRecord => governance::MODULE_PROPOSAL_RECORD,
        OperationId::ModuleProposalList => governance::MODULE_PROPOSAL_LIST,
        OperationId::ModuleProposalInspect => governance::MODULE_PROPOSAL_INSPECT,
        OperationId::ModuleValidationRecord => governance::MODULE_VALIDATION_RECORD,
        OperationId::ModuleValidationList => governance::MODULE_VALIDATION_LIST,
        OperationId::ModuleValidationInspect => governance::MODULE_VALIDATION_INSPECT,
        OperationId::ModuleInstallRequestRecord => governance::MODULE_INSTALL_REQUEST_RECORD,
        OperationId::ModuleInstallRequestList => governance::MODULE_INSTALL_REQUEST_LIST,
        OperationId::ModuleInstallRequestInspect => governance::MODULE_INSTALL_REQUEST_INSPECT,
        OperationId::ModuleInstallDecisionRecord => governance::MODULE_INSTALL_DECISION_RECORD,
        OperationId::ModuleInstallDecisionList => governance::MODULE_INSTALL_DECISION_LIST,
        OperationId::ModuleInstallDecisionInspect => governance::MODULE_INSTALL_DECISION_INSPECT,
        OperationId::ModuleDependencyRequestRecord => governance::MODULE_DEPENDENCY_REQUEST_RECORD,
        OperationId::ModuleDependencyRequestList => governance::MODULE_DEPENDENCY_REQUEST_LIST,
        OperationId::ModuleDependencyRequestInspect => {
            governance::MODULE_DEPENDENCY_REQUEST_INSPECT
        }
        OperationId::ModuleDependencyDecisionRecord => {
            governance::MODULE_DEPENDENCY_DECISION_RECORD
        }
        OperationId::ModuleDependencyDecisionList => governance::MODULE_DEPENDENCY_DECISION_LIST,
        OperationId::ModuleDependencyDecisionInspect => {
            governance::MODULE_DEPENDENCY_DECISION_INSPECT
        }
        OperationId::ModuleDependencyPolicyActivate => {
            governance::MODULE_DEPENDENCY_POLICY_ACTIVATE
        }
        OperationId::ModuleDependencyPolicyList => governance::MODULE_DEPENDENCY_POLICY_LIST,
        OperationId::ModuleDependencyPolicyInspect => governance::MODULE_DEPENDENCY_POLICY_INSPECT,
        OperationId::CapabilityBindingRequestRecord => {
            capability_binding::CAPABILITY_BINDING_REQUEST_RECORD
        }
        OperationId::CapabilityBindingRequestList => {
            capability_binding::CAPABILITY_BINDING_REQUEST_LIST
        }
        OperationId::CapabilityBindingRequestInspect => {
            capability_binding::CAPABILITY_BINDING_REQUEST_INSPECT
        }
        OperationId::CapabilityBindingDecisionRecord => {
            capability_binding::CAPABILITY_BINDING_DECISION_RECORD
        }
        OperationId::CapabilityBindingDecisionList => {
            capability_binding::CAPABILITY_BINDING_DECISION_LIST
        }
        OperationId::CapabilityBindingDecisionInspect => {
            capability_binding::CAPABILITY_BINDING_DECISION_INSPECT
        }
        OperationId::CapabilityBindingPolicyActivate => {
            capability_binding::CAPABILITY_BINDING_POLICY_ACTIVATE
        }
        OperationId::CapabilityBindingPolicyList => {
            capability_binding::CAPABILITY_BINDING_POLICY_LIST
        }
        OperationId::CapabilityBindingPolicyInspect => {
            capability_binding::CAPABILITY_BINDING_POLICY_INSPECT
        }
        OperationId::CapabilityBindingCockpitOverview => {
            capability_binding::CAPABILITY_BINDING_COCKPIT_OVERVIEW
        }
        OperationId::CapabilityShadowTrialRequestRecord => {
            capability_binding::CAPABILITY_SHADOW_TRIAL_REQUEST_RECORD
        }
        OperationId::CapabilityShadowTrialDecisionRecord => {
            capability_binding::CAPABILITY_SHADOW_TRIAL_DECISION_RECORD
        }
        OperationId::CapabilityShadowTrialRunRecord => {
            capability_binding::CAPABILITY_SHADOW_TRIAL_RUN_RECORD
        }
        OperationId::CapabilityShadowTrialEvidenceInspect => {
            capability_binding::CAPABILITY_SHADOW_TRIAL_EVIDENCE_INSPECT
        }
        OperationId::CapabilityReplacementCandidateRecord => {
            capability_binding::CAPABILITY_REPLACEMENT_CANDIDATE_RECORD
        }
        OperationId::CapabilityReplacementCandidateList => {
            capability_binding::CAPABILITY_REPLACEMENT_CANDIDATE_LIST
        }
        OperationId::CapabilityReplacementCandidateInspect => {
            capability_binding::CAPABILITY_REPLACEMENT_CANDIDATE_INSPECT
        }
        OperationId::CapabilityRouteBindingRecord => {
            capability_binding::CAPABILITY_ROUTE_BINDING_RECORD
        }
        OperationId::CapabilityRouteBindingList => {
            capability_binding::CAPABILITY_ROUTE_BINDING_LIST
        }
        OperationId::CapabilityRouteBindingInspect => {
            capability_binding::CAPABILITY_ROUTE_BINDING_INSPECT
        }
        OperationId::CapabilityRouteActivate => capability_binding::CAPABILITY_ROUTE_ACTIVATE,
        OperationId::CapabilityRouteDisable => capability_binding::CAPABILITY_ROUTE_DISABLE,
        OperationId::CapabilityRouteRollback => capability_binding::CAPABILITY_ROUTE_ROLLBACK,
        OperationId::CapabilityRouteEventList => capability_binding::CAPABILITY_ROUTE_EVENT_LIST,
        OperationId::CapabilityRouteEventInspect => {
            capability_binding::CAPABILITY_ROUTE_EVENT_INSPECT
        }
        OperationId::ModuleLifecycleRequest => governance::MODULE_LIFECYCLE_REQUEST,
        OperationId::ModuleLifecycleDecision => governance::MODULE_LIFECYCLE_DECISION,
        OperationId::ModuleLifecycleList => governance::MODULE_LIFECYCLE_LIST,
        OperationId::ModuleLifecycleInspect => governance::MODULE_LIFECYCLE_INSPECT,
        OperationId::ModuleProgramExecutionStart => governance::MODULE_PROGRAM_EXECUTION_START,
        OperationId::ModuleProgramExecutionStatus => governance::MODULE_PROGRAM_EXECUTION_STATUS,
        OperationId::ModuleProgramExecutionCancel => governance::MODULE_PROGRAM_EXECUTION_CANCEL,
        OperationId::ModuleProgramExecutionCleanup => governance::MODULE_PROGRAM_EXECUTION_CLEANUP,
        OperationId::ModuleRuntimeRequest => governance::MODULE_RUNTIME_REQUEST,
        OperationId::ModuleRuntimeList => governance::MODULE_RUNTIME_LIST,
        OperationId::ModuleRuntimeInspect => governance::MODULE_RUNTIME_INSPECT,
        OperationId::ModuleRuntimeCancel => governance::MODULE_RUNTIME_CANCEL,
        OperationId::WebFetch => direct::WEB_FETCH,
        OperationId::WebRobotsCheck => direct::WEB_ROBOTS_CHECK,
        OperationId::WebSourceList => direct::WEB_SOURCE_LIST,
        OperationId::WebSourceInspect => direct::WEB_SOURCE_INSPECT,
        OperationId::WebSourceArchive => direct::WEB_SOURCE_ARCHIVE,
        OperationId::WebResearchRequestRecord => records::WEB_RESEARCH_REQUEST_RECORD,
        OperationId::WebResearchRequestList => records::WEB_RESEARCH_REQUEST_LIST,
        OperationId::WebResearchRequestInspect => records::WEB_RESEARCH_REQUEST_INSPECT,
        OperationId::WebResearchReviewRecord => records::WEB_RESEARCH_REVIEW_RECORD,
        OperationId::WebResearchReviewList => records::WEB_RESEARCH_REVIEW_LIST,
        OperationId::WebResearchReviewInspect => records::WEB_RESEARCH_REVIEW_INSPECT,
        OperationId::WebResearchSourceRecord => records::WEB_RESEARCH_SOURCE_RECORD,
        OperationId::WebResearchSourceList => records::WEB_RESEARCH_SOURCE_LIST,
        OperationId::WebResearchSourceInspect => records::WEB_RESEARCH_SOURCE_INSPECT,
    }
}
