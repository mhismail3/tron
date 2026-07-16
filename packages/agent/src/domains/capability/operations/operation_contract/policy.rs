//! Canonical invocation-context and effect policy for provider-visible operations.

use super::OperationId;
use crate::engine::RiskLevel;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum OperationEffect {
    ReadOnly,
    MetadataWrite,
    StateChange,
    StartsWork,
}

impl OperationEffect {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::MetadataWrite => "metadata_write",
            Self::StateChange => "state_change",
            Self::StartsWork => "starts_work",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InvocationScope {
    None,
    CurrentSession,
    SessionOrWorkspace,
}

pub(super) const fn invocation_scope(operation: OperationId) -> InvocationScope {
    match operation {
        OperationId::CatalogConformance
        | OperationId::CatalogInspect
        | OperationId::CatalogSearch
        | OperationId::FilesystemApplyPatch
        | OperationId::FilesystemDiff
        | OperationId::FilesystemEdit
        | OperationId::FilesystemFind
        | OperationId::FilesystemGlob
        | OperationId::FilesystemList
        | OperationId::FilesystemRead
        | OperationId::FilesystemSearchText
        | OperationId::FilesystemWrite
        | OperationId::GitBranchInventory
        | OperationId::GitBranchStart
        | OperationId::GitCommit
        | OperationId::GitDiff
        | OperationId::GitStage
        | OperationId::GitStatus
        | OperationId::GitUnstage
        | OperationId::Observe
        | OperationId::ProcessRun
        | OperationId::StateGet
        | OperationId::StateList
        | OperationId::StateSet => InvocationScope::None,

        OperationId::ContextControlActionInspect
        | OperationId::ContextControlActionList
        | OperationId::ContextControlClear
        | OperationId::ContextControlCompact
        | OperationId::ContextControlSnapshot
        | OperationId::ContextControlStatus
        | OperationId::ContextExclusionDisable
        | OperationId::ContextExclusionList
        | OperationId::ContextExclusionRecord
        | OperationId::ContextPolicySnapshot
        | OperationId::ContextSurvivorDisable
        | OperationId::ContextSurvivorList
        | OperationId::ContextSurvivorRecord
        | OperationId::GoalCancel
        | OperationId::GoalCreate
        | OperationId::GoalInspect
        | OperationId::GoalList
        | OperationId::JobCancel
        | OperationId::JobList
        | OperationId::JobLog
        | OperationId::JobStart
        | OperationId::JobStatus
        | OperationId::LogRecent
        | OperationId::MemoryDecisionInspect
        | OperationId::MemoryDecisionList
        | OperationId::MemoryInspect
        | OperationId::MemoryList
        | OperationId::MemoryQueryInspect
        | OperationId::MemoryQueryList
        | OperationId::MemoryStatus
        | OperationId::ModuleInspect
        | OperationId::ModuleList
        | OperationId::ModuleProgramExecutionCancel
        | OperationId::ModuleProgramExecutionCleanup
        | OperationId::ModuleProgramExecutionStart
        | OperationId::ModuleProgramExecutionStatus
        | OperationId::NotificationInspect
        | OperationId::NotificationList
        | OperationId::NotificationMarkAllRead
        | OperationId::NotificationMarkRead
        | OperationId::NotificationSend
        | OperationId::ProceduralActivationDecisionInspect
        | OperationId::ProceduralActivationDecisionList
        | OperationId::ProceduralActivationDecisionRecord
        | OperationId::ProceduralActivationRequestInspect
        | OperationId::ProceduralActivationRequestList
        | OperationId::ProceduralActivationRequestRecord
        | OperationId::ProceduralDefinitionRecord
        | OperationId::ProceduralStateInspect
        | OperationId::ProceduralStateList
        | OperationId::QuestionAnswer
        | OperationId::QuestionCreate
        | OperationId::QuestionInspect
        | OperationId::QuestionList
        | OperationId::ReplayManifest
        | OperationId::ScheduleCancel
        | OperationId::ScheduleCreate
        | OperationId::ScheduleFireDue
        | OperationId::ScheduleInspect
        | OperationId::ScheduleList
        | OperationId::SubagentCancel
        | OperationId::SubagentLaunch
        | OperationId::SubagentResult
        | OperationId::SubagentStatus
        | OperationId::SubagentTaskInspect
        | OperationId::SubagentTaskList
        | OperationId::ToolSourceInspect
        | OperationId::ToolSourceList
        | OperationId::TraceGet
        | OperationId::TraceList
        | OperationId::WebFetch
        | OperationId::WebRobotsCheck
        | OperationId::WebSourceArchive
        | OperationId::WebSourceInspect
        | OperationId::WebSourceList
        | OperationId::WorkerPackageInspect
        | OperationId::WorkerPackageList => InvocationScope::CurrentSession,

        OperationId::CapabilityBindingCockpitOverview
        | OperationId::CapabilityBindingDecisionInspect
        | OperationId::CapabilityBindingDecisionList
        | OperationId::CapabilityBindingDecisionRecord
        | OperationId::CapabilityBindingPolicyActivate
        | OperationId::CapabilityBindingPolicyInspect
        | OperationId::CapabilityBindingPolicyList
        | OperationId::CapabilityBindingRequestInspect
        | OperationId::CapabilityBindingRequestList
        | OperationId::CapabilityBindingRequestRecord
        | OperationId::CapabilityReplacementCandidateInspect
        | OperationId::CapabilityReplacementCandidateList
        | OperationId::CapabilityReplacementCandidateRecord
        | OperationId::CapabilityRouteActivate
        | OperationId::CapabilityRouteBindingInspect
        | OperationId::CapabilityRouteBindingList
        | OperationId::CapabilityRouteBindingRecord
        | OperationId::CapabilityRouteDisable
        | OperationId::CapabilityRouteEventInspect
        | OperationId::CapabilityRouteEventList
        | OperationId::CapabilityRouteRollback
        | OperationId::CapabilityShadowTrialDecisionRecord
        | OperationId::CapabilityShadowTrialEvidenceInspect
        | OperationId::CapabilityShadowTrialRequestRecord
        | OperationId::CapabilityShadowTrialRunRecord
        | OperationId::DeviceInspect
        | OperationId::DeviceList
        | OperationId::ImportHistoryInspect
        | OperationId::ImportHistoryList
        | OperationId::ImportHistoryRecord
        | OperationId::ImportPreviewInspect
        | OperationId::ImportPreviewList
        | OperationId::ImportPreviewRecord
        | OperationId::MediaArchive
        | OperationId::MediaCreate
        | OperationId::MediaInspect
        | OperationId::MediaList
        | OperationId::ModuleDependencyDecisionInspect
        | OperationId::ModuleDependencyDecisionList
        | OperationId::ModuleDependencyDecisionRecord
        | OperationId::ModuleDependencyPolicyActivate
        | OperationId::ModuleDependencyPolicyInspect
        | OperationId::ModuleDependencyPolicyList
        | OperationId::ModuleDependencyRequestInspect
        | OperationId::ModuleDependencyRequestList
        | OperationId::ModuleDependencyRequestRecord
        | OperationId::ModuleInstallDecisionInspect
        | OperationId::ModuleInstallDecisionList
        | OperationId::ModuleInstallDecisionRecord
        | OperationId::ModuleInstallRequestInspect
        | OperationId::ModuleInstallRequestList
        | OperationId::ModuleInstallRequestRecord
        | OperationId::ModuleLifecycleDecision
        | OperationId::ModuleLifecycleInspect
        | OperationId::ModuleLifecycleList
        | OperationId::ModuleLifecycleRequest
        | OperationId::ModuleProposalInspect
        | OperationId::ModuleProposalList
        | OperationId::ModuleProposalRecord
        | OperationId::ModuleRuntimeCancel
        | OperationId::ModuleRuntimeInspect
        | OperationId::ModuleRuntimeList
        | OperationId::ModuleRuntimeRequest
        | OperationId::ModuleValidationInspect
        | OperationId::ModuleValidationList
        | OperationId::ModuleValidationRecord
        | OperationId::ProgramExecutionInspect
        | OperationId::ProgramExecutionList
        | OperationId::ProgramExecutionRecord
        | OperationId::PromptArtifactInspect
        | OperationId::PromptArtifactList
        | OperationId::PromptArtifactRecord
        | OperationId::RepositoryTreeInspect
        | OperationId::RepositoryTreeList
        | OperationId::RepositoryTreeSnapshot
        | OperationId::UpdateDiagnosticInspect
        | OperationId::UpdateDiagnosticList
        | OperationId::UpdateDiagnosticRecord
        | OperationId::WebResearchRequestInspect
        | OperationId::WebResearchRequestList
        | OperationId::WebResearchRequestRecord
        | OperationId::WebResearchReviewInspect
        | OperationId::WebResearchReviewList
        | OperationId::WebResearchReviewRecord
        | OperationId::WebResearchSourceInspect
        | OperationId::WebResearchSourceList
        | OperationId::WebResearchSourceRecord => InvocationScope::SessionOrWorkspace,
    }
}

pub(super) const fn effect(operation: OperationId) -> OperationEffect {
    match operation {
        OperationId::CapabilityBindingCockpitOverview
        | OperationId::CapabilityBindingDecisionInspect
        | OperationId::CapabilityBindingDecisionList
        | OperationId::CapabilityBindingPolicyInspect
        | OperationId::CapabilityBindingPolicyList
        | OperationId::CapabilityBindingRequestInspect
        | OperationId::CapabilityBindingRequestList
        | OperationId::CapabilityReplacementCandidateInspect
        | OperationId::CapabilityReplacementCandidateList
        | OperationId::CapabilityRouteBindingInspect
        | OperationId::CapabilityRouteBindingList
        | OperationId::CapabilityRouteEventInspect
        | OperationId::CapabilityRouteEventList
        | OperationId::CapabilityShadowTrialEvidenceInspect
        | OperationId::CatalogInspect
        | OperationId::CatalogSearch
        | OperationId::ContextControlActionInspect
        | OperationId::ContextControlActionList
        | OperationId::ContextControlStatus
        | OperationId::ContextExclusionList
        | OperationId::ContextSurvivorList
        | OperationId::DeviceInspect
        | OperationId::DeviceList
        | OperationId::FilesystemDiff
        | OperationId::FilesystemFind
        | OperationId::FilesystemGlob
        | OperationId::FilesystemList
        | OperationId::FilesystemRead
        | OperationId::FilesystemSearchText
        | OperationId::GitBranchInventory
        | OperationId::GitDiff
        | OperationId::GitStatus
        | OperationId::GoalInspect
        | OperationId::GoalList
        | OperationId::ImportHistoryInspect
        | OperationId::ImportHistoryList
        | OperationId::ImportPreviewInspect
        | OperationId::ImportPreviewList
        | OperationId::JobList
        | OperationId::JobLog
        | OperationId::JobStatus
        | OperationId::LogRecent
        | OperationId::MediaInspect
        | OperationId::MediaList
        | OperationId::MemoryDecisionInspect
        | OperationId::MemoryDecisionList
        | OperationId::MemoryInspect
        | OperationId::MemoryList
        | OperationId::MemoryQueryInspect
        | OperationId::MemoryQueryList
        | OperationId::MemoryStatus
        | OperationId::ModuleDependencyDecisionInspect
        | OperationId::ModuleDependencyDecisionList
        | OperationId::ModuleDependencyPolicyInspect
        | OperationId::ModuleDependencyPolicyList
        | OperationId::ModuleDependencyRequestInspect
        | OperationId::ModuleDependencyRequestList
        | OperationId::ModuleInspect
        | OperationId::ModuleInstallDecisionInspect
        | OperationId::ModuleInstallDecisionList
        | OperationId::ModuleInstallRequestInspect
        | OperationId::ModuleInstallRequestList
        | OperationId::ModuleLifecycleInspect
        | OperationId::ModuleLifecycleList
        | OperationId::ModuleList
        | OperationId::ModuleProgramExecutionStatus
        | OperationId::ModuleProposalInspect
        | OperationId::ModuleProposalList
        | OperationId::ModuleRuntimeInspect
        | OperationId::ModuleRuntimeList
        | OperationId::ModuleValidationInspect
        | OperationId::ModuleValidationList
        | OperationId::NotificationInspect
        | OperationId::NotificationList
        | OperationId::Observe
        | OperationId::ProceduralActivationDecisionInspect
        | OperationId::ProceduralActivationDecisionList
        | OperationId::ProceduralActivationRequestInspect
        | OperationId::ProceduralActivationRequestList
        | OperationId::ProceduralStateInspect
        | OperationId::ProceduralStateList
        | OperationId::ProgramExecutionInspect
        | OperationId::ProgramExecutionList
        | OperationId::PromptArtifactInspect
        | OperationId::PromptArtifactList
        | OperationId::QuestionInspect
        | OperationId::QuestionList
        | OperationId::ReplayManifest
        | OperationId::RepositoryTreeInspect
        | OperationId::RepositoryTreeList
        | OperationId::ScheduleInspect
        | OperationId::ScheduleList
        | OperationId::StateGet
        | OperationId::StateList
        | OperationId::SubagentResult
        | OperationId::SubagentStatus
        | OperationId::SubagentTaskInspect
        | OperationId::SubagentTaskList
        | OperationId::ToolSourceInspect
        | OperationId::ToolSourceList
        | OperationId::TraceGet
        | OperationId::TraceList
        | OperationId::UpdateDiagnosticInspect
        | OperationId::UpdateDiagnosticList
        | OperationId::WebResearchRequestInspect
        | OperationId::WebResearchRequestList
        | OperationId::WebResearchReviewInspect
        | OperationId::WebResearchReviewList
        | OperationId::WebResearchSourceInspect
        | OperationId::WebResearchSourceList
        | OperationId::WebSourceInspect
        | OperationId::WebSourceList
        | OperationId::WorkerPackageInspect
        | OperationId::WorkerPackageList => OperationEffect::ReadOnly,

        OperationId::JobStart
        | OperationId::ModuleProgramExecutionStart
        | OperationId::ModuleRuntimeRequest
        | OperationId::ProcessRun
        | OperationId::ScheduleFireDue
        | OperationId::SubagentLaunch => OperationEffect::StartsWork,

        OperationId::CapabilityBindingDecisionRecord
        | OperationId::CapabilityBindingPolicyActivate
        | OperationId::CapabilityBindingRequestRecord
        | OperationId::CapabilityReplacementCandidateRecord
        | OperationId::CapabilityRouteActivate
        | OperationId::CapabilityRouteBindingRecord
        | OperationId::CapabilityRouteDisable
        | OperationId::CapabilityRouteRollback
        | OperationId::CapabilityShadowTrialDecisionRecord
        | OperationId::CapabilityShadowTrialRequestRecord
        | OperationId::CapabilityShadowTrialRunRecord
        | OperationId::CatalogConformance
        | OperationId::ContextControlClear
        | OperationId::ContextControlCompact
        | OperationId::ContextControlSnapshot
        | OperationId::ContextExclusionDisable
        | OperationId::ContextExclusionRecord
        | OperationId::ContextPolicySnapshot
        | OperationId::ContextSurvivorDisable
        | OperationId::ContextSurvivorRecord
        | OperationId::ImportHistoryRecord
        | OperationId::ImportPreviewRecord
        | OperationId::MediaArchive
        | OperationId::MediaCreate
        | OperationId::ModuleDependencyDecisionRecord
        | OperationId::ModuleDependencyPolicyActivate
        | OperationId::ModuleDependencyRequestRecord
        | OperationId::ModuleInstallDecisionRecord
        | OperationId::ModuleInstallRequestRecord
        | OperationId::ModuleLifecycleDecision
        | OperationId::ModuleLifecycleRequest
        | OperationId::ModuleProposalRecord
        | OperationId::ModuleRuntimeCancel
        | OperationId::ModuleValidationRecord
        | OperationId::ProceduralActivationDecisionRecord
        | OperationId::ProceduralActivationRequestRecord
        | OperationId::ProceduralDefinitionRecord
        | OperationId::ProgramExecutionRecord
        | OperationId::PromptArtifactRecord
        | OperationId::StateSet
        | OperationId::UpdateDiagnosticRecord
        | OperationId::WebResearchRequestRecord
        | OperationId::WebResearchReviewRecord
        | OperationId::WebResearchSourceRecord => OperationEffect::MetadataWrite,

        OperationId::FilesystemApplyPatch
        | OperationId::FilesystemEdit
        | OperationId::FilesystemWrite
        | OperationId::GitBranchStart
        | OperationId::GitCommit
        | OperationId::GitStage
        | OperationId::GitUnstage
        | OperationId::GoalCancel
        | OperationId::GoalCreate
        | OperationId::JobCancel
        | OperationId::ModuleProgramExecutionCancel
        | OperationId::ModuleProgramExecutionCleanup
        | OperationId::NotificationMarkAllRead
        | OperationId::NotificationMarkRead
        | OperationId::NotificationSend
        | OperationId::QuestionAnswer
        | OperationId::QuestionCreate
        | OperationId::RepositoryTreeSnapshot
        | OperationId::ScheduleCancel
        | OperationId::ScheduleCreate
        | OperationId::SubagentCancel
        | OperationId::WebFetch
        | OperationId::WebRobotsCheck
        | OperationId::WebSourceArchive => OperationEffect::StateChange,
    }
}

pub(super) const fn risk(operation: OperationId) -> RiskLevel {
    match operation {
        OperationId::CapabilityBindingPolicyActivate
        | OperationId::CapabilityRouteActivate
        | OperationId::CapabilityRouteDisable
        | OperationId::CapabilityRouteRollback
        | OperationId::ContextControlClear
        | OperationId::ModuleDependencyPolicyActivate
        | OperationId::ModuleLifecycleDecision => RiskLevel::High,
        operation => match effect(operation) {
            OperationEffect::ReadOnly => RiskLevel::Low,
            OperationEffect::MetadataWrite => RiskLevel::Medium,
            OperationEffect::StateChange | OperationEffect::StartsWork => RiskLevel::High,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::super::supported_operation_names;
    use super::*;

    #[test]
    fn every_supported_operation_has_one_effect() {
        for operation in supported_operation_names() {
            let operation_id = OperationId::parse(operation).expect("supported operation id");
            let _ = effect(operation_id);
        }
    }

    #[test]
    fn risk_is_derived_from_effect_with_explicit_governance_overrides() {
        assert_eq!(risk(OperationId::GitStatus), RiskLevel::Low);
        assert_eq!(risk(OperationId::ContextControlSnapshot), RiskLevel::Medium);
        assert_eq!(risk(OperationId::FilesystemWrite), RiskLevel::High);
        assert_eq!(risk(OperationId::ContextControlClear), RiskLevel::High);
        assert_eq!(risk(OperationId::CapabilityRouteActivate), RiskLevel::High);
    }

    #[test]
    fn invocation_scope_distinguishes_session_and_workspace_capable_records() {
        for operation in [
            "media_create",
            "repository_tree_list",
            "program_execution_inspect",
            "device_list",
        ] {
            let operation_id = OperationId::parse(operation).expect("supported operation id");
            assert_eq!(
                invocation_scope(operation_id),
                InvocationScope::SessionOrWorkspace,
                "{operation}"
            );
        }
        assert_eq!(
            invocation_scope(OperationId::ContextControlSnapshot),
            InvocationScope::CurrentSession
        );
        assert_eq!(
            invocation_scope(OperationId::GitStatus),
            InvocationScope::None
        );
        assert_eq!(
            invocation_scope(OperationId::CapabilityRouteActivate),
            InvocationScope::SessionOrWorkspace
        );
    }
}
