use super::super::OperationId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum OutputProfile {
    Summary,
    Catalog,
    Filesystem,
    Git,
    Runtime,
    TraceAudit,
    Context,
    Resource,
    Governance,
    Web,
}

impl OutputProfile {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Summary => "summary",
            Self::Catalog => "catalog",
            Self::Filesystem => "filesystem",
            Self::Git => "git",
            Self::Runtime => "runtime",
            Self::TraceAudit => "trace_audit",
            Self::Context => "context",
            Self::Resource => "resource",
            Self::Governance => "governance",
            Self::Web => "web",
        }
    }
}

#[allow(clippy::too_many_lines)]
pub(super) const fn profile(operation: OperationId) -> OutputProfile {
    match operation {
        OperationId::Observe
        | OperationId::StateGet
        | OperationId::StateSet
        | OperationId::StateList => OutputProfile::Summary,
        OperationId::CatalogSearch
        | OperationId::CatalogInspect
        | OperationId::CatalogConformance => OutputProfile::Catalog,
        OperationId::FilesystemRead
        | OperationId::FilesystemList
        | OperationId::FilesystemFind
        | OperationId::FilesystemGlob
        | OperationId::FilesystemSearchText
        | OperationId::FilesystemDiff
        | OperationId::FilesystemWrite
        | OperationId::FilesystemEdit
        | OperationId::FilesystemApplyPatch => OutputProfile::Filesystem,
        OperationId::GitStatus
        | OperationId::GitDiff
        | OperationId::GitBranchInventory
        | OperationId::GitStage
        | OperationId::GitUnstage
        | OperationId::GitCommit
        | OperationId::GitBranchStart => OutputProfile::Git,
        OperationId::ProcessRun
        | OperationId::JobStart
        | OperationId::JobStatus
        | OperationId::JobList
        | OperationId::JobLog
        | OperationId::JobCancel
        | OperationId::SubagentLaunch
        | OperationId::SubagentStatus
        | OperationId::SubagentResult
        | OperationId::SubagentCancel
        | OperationId::ModuleProgramExecutionStart
        | OperationId::ModuleProgramExecutionStatus
        | OperationId::ModuleProgramExecutionCancel
        | OperationId::ModuleProgramExecutionCleanup
        | OperationId::ModuleRuntimeRequest
        | OperationId::ModuleRuntimeList
        | OperationId::ModuleRuntimeInspect
        | OperationId::ModuleRuntimeCancel => OutputProfile::Runtime,
        OperationId::TraceList
        | OperationId::TraceGet
        | OperationId::LogRecent
        | OperationId::ReplayManifest => OutputProfile::TraceAudit,
        OperationId::ContextControlStatus
        | OperationId::ContextControlSnapshot
        | OperationId::ContextControlCompact
        | OperationId::ContextControlClear
        | OperationId::ContextControlActionList
        | OperationId::ContextControlActionInspect
        | OperationId::ContextSurvivorRecord
        | OperationId::ContextSurvivorList
        | OperationId::ContextSurvivorDisable
        | OperationId::ContextExclusionRecord
        | OperationId::ContextExclusionList
        | OperationId::ContextExclusionDisable
        | OperationId::ContextPolicySnapshot => OutputProfile::Context,
        OperationId::GoalCreate
        | OperationId::GoalList
        | OperationId::GoalInspect
        | OperationId::GoalCancel
        | OperationId::QuestionCreate
        | OperationId::QuestionList
        | OperationId::QuestionInspect
        | OperationId::QuestionAnswer
        | OperationId::MemoryStatus
        | OperationId::MemoryList
        | OperationId::MemoryInspect
        | OperationId::MemoryQueryList
        | OperationId::MemoryQueryInspect
        | OperationId::MemoryDecisionList
        | OperationId::MemoryDecisionInspect
        | OperationId::MediaCreate
        | OperationId::MediaList
        | OperationId::MediaInspect
        | OperationId::MediaArchive
        | OperationId::ImportHistoryRecord
        | OperationId::ImportHistoryList
        | OperationId::ImportHistoryInspect
        | OperationId::RepositoryTreeSnapshot
        | OperationId::RepositoryTreeList
        | OperationId::RepositoryTreeInspect
        | OperationId::ImportPreviewRecord
        | OperationId::ImportPreviewList
        | OperationId::ImportPreviewInspect
        | OperationId::ProgramExecutionRecord
        | OperationId::ProgramExecutionList
        | OperationId::ProgramExecutionInspect
        | OperationId::PromptArtifactRecord
        | OperationId::PromptArtifactList
        | OperationId::PromptArtifactInspect
        | OperationId::UpdateDiagnosticRecord
        | OperationId::UpdateDiagnosticList
        | OperationId::UpdateDiagnosticInspect
        | OperationId::DeviceList
        | OperationId::DeviceInspect
        | OperationId::NotificationSend
        | OperationId::NotificationList
        | OperationId::NotificationInspect
        | OperationId::NotificationMarkRead
        | OperationId::NotificationMarkAllRead
        | OperationId::ScheduleCreate
        | OperationId::ScheduleList
        | OperationId::ScheduleInspect
        | OperationId::ScheduleCancel
        | OperationId::ScheduleFireDue
        | OperationId::SubagentTaskList
        | OperationId::SubagentTaskInspect => OutputProfile::Resource,
        OperationId::ProceduralDefinitionRecord
        | OperationId::ProceduralStateList
        | OperationId::ProceduralStateInspect
        | OperationId::ProceduralActivationRequestRecord
        | OperationId::ProceduralActivationRequestList
        | OperationId::ProceduralActivationRequestInspect
        | OperationId::ProceduralActivationDecisionRecord
        | OperationId::ProceduralActivationDecisionList
        | OperationId::ProceduralActivationDecisionInspect
        | OperationId::ToolSourceList
        | OperationId::ToolSourceInspect
        | OperationId::WorkerPackageList
        | OperationId::WorkerPackageInspect
        | OperationId::ModuleList
        | OperationId::ModuleInspect
        | OperationId::ModuleProposalRecord
        | OperationId::ModuleProposalList
        | OperationId::ModuleProposalInspect
        | OperationId::ModuleValidationRecord
        | OperationId::ModuleValidationList
        | OperationId::ModuleValidationInspect
        | OperationId::ModuleInstallRequestRecord
        | OperationId::ModuleInstallRequestList
        | OperationId::ModuleInstallRequestInspect
        | OperationId::ModuleInstallDecisionRecord
        | OperationId::ModuleInstallDecisionList
        | OperationId::ModuleInstallDecisionInspect
        | OperationId::ModuleDependencyRequestRecord
        | OperationId::ModuleDependencyRequestList
        | OperationId::ModuleDependencyRequestInspect
        | OperationId::ModuleDependencyDecisionRecord
        | OperationId::ModuleDependencyDecisionList
        | OperationId::ModuleDependencyDecisionInspect
        | OperationId::ModuleDependencyPolicyActivate
        | OperationId::ModuleDependencyPolicyList
        | OperationId::ModuleDependencyPolicyInspect
        | OperationId::CapabilityBindingRequestRecord
        | OperationId::CapabilityBindingRequestList
        | OperationId::CapabilityBindingRequestInspect
        | OperationId::CapabilityBindingDecisionRecord
        | OperationId::CapabilityBindingDecisionList
        | OperationId::CapabilityBindingDecisionInspect
        | OperationId::CapabilityBindingPolicyActivate
        | OperationId::CapabilityBindingPolicyList
        | OperationId::CapabilityBindingPolicyInspect
        | OperationId::CapabilityBindingCockpitOverview
        | OperationId::CapabilityShadowTrialRequestRecord
        | OperationId::CapabilityShadowTrialDecisionRecord
        | OperationId::CapabilityShadowTrialRunRecord
        | OperationId::CapabilityShadowTrialEvidenceInspect
        | OperationId::CapabilityReplacementCandidateRecord
        | OperationId::CapabilityReplacementCandidateList
        | OperationId::CapabilityReplacementCandidateInspect
        | OperationId::CapabilityRouteBindingRecord
        | OperationId::CapabilityRouteBindingList
        | OperationId::CapabilityRouteBindingInspect
        | OperationId::CapabilityRouteActivate
        | OperationId::CapabilityRouteDisable
        | OperationId::CapabilityRouteRollback
        | OperationId::CapabilityRouteEventList
        | OperationId::CapabilityRouteEventInspect
        | OperationId::ModuleLifecycleRequest
        | OperationId::ModuleLifecycleDecision
        | OperationId::ModuleLifecycleList
        | OperationId::ModuleLifecycleInspect => OutputProfile::Governance,
        OperationId::WebFetch
        | OperationId::WebRobotsCheck
        | OperationId::WebSourceList
        | OperationId::WebSourceInspect
        | OperationId::WebSourceArchive
        | OperationId::WebResearchRequestRecord
        | OperationId::WebResearchRequestList
        | OperationId::WebResearchRequestInspect
        | OperationId::WebResearchReviewRecord
        | OperationId::WebResearchReviewList
        | OperationId::WebResearchReviewInspect
        | OperationId::WebResearchSourceRecord
        | OperationId::WebResearchSourceList
        | OperationId::WebResearchSourceInspect => OutputProfile::Web,
    }
}
