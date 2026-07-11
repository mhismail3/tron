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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SummaryPolicy {
    /// Use the operation-authored summary after provider-boundary sanitization.
    SanitizedOperationContent,
}

impl SummaryPolicy {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::SanitizedOperationContent => "sanitized_operation_content",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct SemanticEvidenceContract {
    pub(super) description: &'static str,
    pub(super) required_fact_fields: &'static [&'static str],
    pub(super) expected_collection_fields: &'static [&'static str],
    pub(super) expected_resource_kinds: &'static [&'static str],
    pub(super) safety_exclusions: &'static [&'static str],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OutputContract {
    pub(super) profile: OutputProfile,
    pub(super) summary_policy: SummaryPolicy,
    pub(super) semantic_evidence: SemanticEvidenceContract,
}

const COMMON_FACTS: &[&str] = &["primitiveOperation", "status"];
const COMMON_EXCLUSIONS: &[&str] = &[
    "secrets and credentials",
    "raw authority and grant identifiers",
    "raw provider invocation identifiers",
    "absolute and parent-relative local paths",
];

pub(super) const fn contract(operation: OperationId) -> OutputContract {
    OutputContract {
        profile: profile(operation),
        summary_policy: SummaryPolicy::SanitizedOperationContent,
        semantic_evidence: semantic_evidence(operation),
    }
}

pub(super) const fn unsupported_contract() -> OutputContract {
    OutputContract {
        profile: OutputProfile::Summary,
        summary_policy: SummaryPolicy::SanitizedOperationContent,
        semantic_evidence: SemanticEvidenceContract {
            description: "Typed failure and recovery guidance for an unsupported operation name.",
            required_fact_fields: &[],
            expected_collection_fields: &[],
            expected_resource_kinds: &[],
            safety_exclusions: COMMON_EXCLUSIONS,
        },
    }
}

const fn semantic_evidence(operation: OperationId) -> SemanticEvidenceContract {
    match operation {
        OperationId::GitStatus => SemanticEvidenceContract {
            description: "Provider-safe repository status facts, bounded change counts, and evidence refs.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "git.schemaVersion",
                "git.operation",
            ],
            expected_collection_fields: &["git.evidence.resourceRefs.returned"],
            expected_resource_kinds: &["git_status_evidence"],
            safety_exclusions: &[
                "absolute paths",
                "raw commands and logs",
                "raw authority and grant identifiers",
            ],
        },
        OperationId::WebRobotsCheck => SemanticEvidenceContract {
            description: "Robots-policy decision plus copy-ready policy resource and version refs for web_fetch.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "web.schemaVersion",
                "web.operation",
                "web.webRobotsPolicyResourceId",
                "web.webRobotsPolicyVersionId",
            ],
            expected_collection_fields: &["web.resourceRefs.items"],
            expected_resource_kinds: &["web_robots_policy"],
            safety_exclusions: COMMON_EXCLUSIONS,
        },
        OperationId::WebFetch => SemanticEvidenceContract {
            description: "Bounded web-source custody refs and robots-policy linkage without raw response bytes.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "web.schemaVersion",
                "web.operation",
                "web.webSourceResourceId",
                "web.webSourceVersionId",
            ],
            expected_collection_fields: &["web.resourceRefs.items"],
            expected_resource_kinds: &["web_source"],
            safety_exclusions: &[
                "raw response bytes and HTML",
                "secrets and credentials",
                "raw authority and grant identifiers",
                "absolute local paths",
            ],
        },
        OperationId::JobStatus => SemanticEvidenceContract {
            description: "One durable job lifecycle projection and bounded output refs without command or stream contents.",
            required_fact_fields: &["primitiveOperation", "status", "jobs.schemaVersion"],
            expected_collection_fields: &["jobs.resourceRefs.items"],
            expected_resource_kinds: &["job_process", "execution_output"],
            safety_exclusions: &[
                "raw commands and working directories",
                "raw stdout and stderr",
                "raw idempotency keys",
                "raw authority and grant identifiers",
            ],
        },
        OperationId::JobList => SemanticEvidenceContract {
            description: "Durable job lifecycle and bounded output refs without command or stream contents.",
            required_fact_fields: &["primitiveOperation", "status", "jobs.schemaVersion"],
            expected_collection_fields: &["jobs.jobs.items"],
            expected_resource_kinds: &["job_process", "execution_output"],
            safety_exclusions: &[
                "raw commands and working directories",
                "raw stdout and stderr",
                "raw idempotency keys",
                "raw authority and grant identifiers",
            ],
        },
        OperationId::JobLog => SemanticEvidenceContract {
            description: "Explicit bounded stdout/stderr previews for one durable job with output custody refs.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "jobs.schemaVersion",
                "jobs.jobResourceId",
                "jobs.jobVersionId",
            ],
            expected_collection_fields: &["jobs.resourceRefs.items"],
            expected_resource_kinds: &["job_process", "execution_output"],
            safety_exclusions: &[
                "raw working directories",
                "raw idempotency keys",
                "raw authority and grant identifiers",
                "unbounded output",
            ],
        },
        OperationId::TraceList => SemanticEvidenceContract {
            description: "Current-session provider-safe trace records and projection-boundary proof.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "projectionBoundary.providerVisibleProjection",
                "statusSummary.totalRecords",
            ],
            expected_collection_fields: &["records"],
            expected_resource_kinds: &["trace_record"],
            safety_exclusions: &[
                "raw provider invocation identifiers",
                "raw requests and results",
                "raw commands logs and file contents",
                "raw authority grant and idempotency identifiers",
            ],
        },
        OperationId::TraceGet => SemanticEvidenceContract {
            description: "One provider-safe trace record and projection-boundary proof.",
            required_fact_fields: &[
                "primitiveOperation",
                "status",
                "projectionBoundary.providerVisibleProjection",
                "record.schemaVersion",
            ],
            expected_collection_fields: &[],
            expected_resource_kinds: &["trace_record"],
            safety_exclusions: &[
                "raw provider invocation identifiers",
                "raw requests and results",
                "raw commands logs and file contents",
                "raw authority grant and idempotency identifiers",
            ],
        },
        _ => SemanticEvidenceContract {
            description: "Operation-specific bounded facts, resource refs, and collections normalized into the canonical provider envelope.",
            required_fact_fields: COMMON_FACTS,
            expected_collection_fields: &[],
            expected_resource_kinds: &[],
            safety_exclusions: COMMON_EXCLUSIONS,
        },
    }
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
