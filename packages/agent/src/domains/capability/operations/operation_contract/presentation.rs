//! Canonical provider-visible presentation metadata for execute operations.
//!
//! This module is the single private owner of the friendly display name and
//! concise behavior summary consumed by capability cockpit projections.
//! Canonical operation identity remains owned by
//! `operation_contract::OperationId`.
//!
//! # Invariants
//!
//! - operation_presentation returns None when OperationId::parse rejects an
//!   unknown operation.
//! - presentation is an exhaustive OperationId match without a wildcard, so
//!   adding an operation requires explicit provider-visible metadata.
//! - Display names and descriptions are provider/native-visible contract bytes
//!   owned only by this module.
//! - Tests derive exhaustiveness and style checks from the canonical operation
//!   registry and keep representative compatibility cases without a duplicate
//!   full literal oracle.

use super::OperationId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OperationPresentation {
    pub(crate) display_name: &'static str,
    pub(crate) description: &'static str,
}

const fn presented(display_name: &'static str, description: &'static str) -> OperationPresentation {
    OperationPresentation {
        display_name,
        description,
    }
}
pub(crate) fn operation_presentation(operation: &str) -> Option<OperationPresentation> {
    OperationId::parse(operation).map(presentation)
}

const fn presentation(operation: OperationId) -> OperationPresentation {
    match operation {
        OperationId::Observe => presented(
            "Record Observation",
            "Add a bounded observation to the current assistant-visible work stream.",
        ),
        OperationId::StateGet => presented(
            "Get State",
            "Read one value from engine-owned state in the current scope.",
        ),
        OperationId::StateSet => presented(
            "Update State",
            "Write one value to engine-owned state in the current scope.",
        ),
        OperationId::StateList => presented(
            "List State",
            "List engine-owned state entries for a scope and namespace.",
        ),
        OperationId::FilesystemRead => presented(
            "Read File",
            "Read a bounded text preview beneath the trusted workspace root.",
        ),
        OperationId::FilesystemList => presented(
            "List Files",
            "List bounded directory entries beneath the trusted workspace root.",
        ),
        OperationId::FilesystemFind => presented(
            "Find Files",
            "Find bounded paths by name without following symbolic links.",
        ),
        OperationId::FilesystemGlob => presented(
            "Match Files by Pattern",
            "Find bounded paths that match a workspace-relative glob pattern.",
        ),
        OperationId::FilesystemSearchText => presented(
            "Search File Text",
            "Search bounded text previews while skipping binary file content.",
        ),
        OperationId::FilesystemDiff => presented(
            "Preview File Changes",
            "Compare current file content with a proposed bounded text change.",
        ),
        OperationId::FilesystemWrite => presented(
            "Write File",
            "Preview or commit a guarded file write with verifiable evidence.",
        ),
        OperationId::FilesystemEdit => presented(
            "Edit File",
            "Preview or commit one exact guarded text replacement.",
        ),
        OperationId::FilesystemApplyPatch => presented(
            "Apply File Patch",
            "Apply an exact guarded text patch with bounded evidence.",
        ),
        OperationId::GitStatus => presented(
            "Inspect Git Status",
            "Inspect branch, upstream, and bounded working-tree status without changing the repository.",
        ),
        OperationId::GitDiff => presented(
            "Inspect Git Changes",
            "Read bounded staged and unstaged change evidence without running external helpers.",
        ),
        OperationId::GitBranchInventory => presented(
            "List Git Branches",
            "List local branches, revisions, upstreams, and ahead or behind status.",
        ),
        OperationId::GitStage => presented(
            "Stage File",
            "Stage one explicit workspace-relative path after repository freshness checks.",
        ),
        OperationId::GitUnstage => presented(
            "Unstage File",
            "Remove one explicit workspace-relative path from the Git index.",
        ),
        OperationId::GitCommit => presented(
            "Create Git Commit",
            "Create one guarded commit from the already staged Git index.",
        ),
        OperationId::GitBranchStart => presented(
            "Start Git Branch",
            "Create and select a new local branch without changing workspace content.",
        ),
        OperationId::ProcessRun => presented(
            "Run Process",
            "Run a bounded local command with timeout, output, and no-network enforcement.",
        ),
        OperationId::JobStart => presented(
            "Start Job",
            "Start a supervised durable command job with bounded output and lifecycle evidence.",
        ),
        OperationId::JobStatus => presented(
            "Inspect Job Status",
            "Inspect a durable job's redacted lifecycle, timing, and output references.",
        ),
        OperationId::JobList => presented(
            "List Jobs",
            "List durable jobs in the current scope with bounded lifecycle summaries.",
        ),
        OperationId::JobLog => presented(
            "Read Job Output",
            "Read bounded standard-output and standard-error previews for one durable job.",
        ),
        OperationId::JobCancel => presented(
            "Cancel Job",
            "Request guarded cancellation of a running durable job.",
        ),
        OperationId::GoalCreate => presented(
            "Create Goal",
            "Create a durable scoped goal with lifecycle and evidence references.",
        ),
        OperationId::GoalList => presented(
            "List Goals",
            "List scoped goals with bounded lifecycle summaries and navigation references.",
        ),
        OperationId::GoalInspect => presented(
            "Inspect Goal",
            "Inspect one scoped goal and its current lifecycle evidence.",
        ),
        OperationId::GoalCancel => presented(
            "Cancel Goal",
            "Cancel one nonterminal goal after freshness and idempotency checks.",
        ),
        OperationId::QuestionCreate => presented(
            "Ask User Question",
            "Create a durable scoped question with answer choices and expiry metadata.",
        ),
        OperationId::QuestionList => presented(
            "List User Questions",
            "List scoped questions with bounded state and answer-navigation summaries.",
        ),
        OperationId::QuestionInspect => presented(
            "Inspect User Question",
            "Inspect one scoped question and its current answer state.",
        ),
        OperationId::QuestionAnswer => presented(
            "Record User Answer",
            "Record an idempotent answer handoff for one pending question.",
        ),
        OperationId::TraceList => presented(
            "List Execution Traces",
            "List bounded provider-safe execution traces for the current session.",
        ),
        OperationId::TraceGet => presented(
            "Inspect Execution Trace",
            "Inspect one provider-safe execution trace by its exact record reference.",
        ),
        OperationId::LogRecent => presented(
            "Read Recent Logs",
            "Read bounded recent engine log evidence with optional trace filtering.",
        ),
        OperationId::ReplayManifest => presented(
            "Export Replay Manifest",
            "Export the current session's replay hashes and cross-record references.",
        ),
        OperationId::CatalogSearch => presented(
            "Search Capability Catalog",
            "Find visible operations and engine functions without invoking them.",
        ),
        OperationId::CatalogInspect => presented(
            "Inspect Capability Contract",
            "Inspect one operation, function, worker, or trigger contract without invoking it.",
        ),
        OperationId::CatalogConformance => presented(
            "Verify Capability Catalog",
            "Record a catalog conformance report and its verification evidence.",
        ),
        OperationId::MemoryStatus => presented(
            "Inspect Memory Status",
            "Inspect current memory policy, engine identity, and prompt-inclusion state.",
        ),
        OperationId::MemoryList => presented(
            "List Memory Records",
            "List redacted memory records for the current session.",
        ),
        OperationId::MemoryInspect => presented(
            "Inspect Memory Record",
            "Inspect one redacted memory record and its version history.",
        ),
        OperationId::MemoryQueryList => presented(
            "List Memory Queries",
            "List redacted memory-query evidence and ranked record references.",
        ),
        OperationId::MemoryQueryInspect => presented(
            "Inspect Memory Query",
            "Inspect one redacted memory-query result and its retrieval evidence.",
        ),
        OperationId::MemoryDecisionList => presented(
            "List Memory Decisions",
            "List memory inclusion decisions with bounded policy evidence.",
        ),
        OperationId::MemoryDecisionInspect => presented(
            "Inspect Memory Decision",
            "Inspect one memory inclusion decision and its policy evidence.",
        ),
        OperationId::ContextControlStatus => presented(
            "Inspect Context Status",
            "Inspect current context composition, token estimates, references, and freshness.",
        ),
        OperationId::ContextControlSnapshot => presented(
            "Snapshot Context",
            "Record a provider-safe snapshot of the current session context.",
        ),
        OperationId::ContextControlCompact => presented(
            "Compact Context",
            "Record and apply a bounded context-compaction boundary without deleting history.",
        ),
        OperationId::ContextControlClear => presented(
            "Clear Active Context",
            "Start a new context epoch while preserving inspectable history and evidence.",
        ),
        OperationId::ContextControlActionList => presented(
            "List Context Actions",
            "List provider-safe summaries of context-control actions in the current session.",
        ),
        OperationId::ContextControlActionInspect => presented(
            "Inspect Context Action",
            "Inspect one context-control action and its preflight and result evidence.",
        ),
        OperationId::ContextSurvivorRecord => presented(
            "Preserve Context Reference",
            "Record a safe reference that future context compaction must preserve.",
        ),
        OperationId::ContextSurvivorList => presented(
            "List Preserved Context",
            "List active safe references that future context compaction must preserve.",
        ),
        OperationId::ContextSurvivorDisable => presented(
            "Stop Preserving Context",
            "Disable one active preserved-context policy after freshness checks.",
        ),
        OperationId::ContextExclusionRecord => presented(
            "Exclude Context Reference",
            "Record a safe reference that future provider context must omit.",
        ),
        OperationId::ContextExclusionList => presented(
            "List Excluded Context",
            "List active safe references that future provider context must omit.",
        ),
        OperationId::ContextExclusionDisable => presented(
            "Stop Excluding Context",
            "Disable one active context-exclusion policy after freshness checks.",
        ),
        OperationId::ContextPolicySnapshot => presented(
            "Snapshot Context Policy",
            "Record the complete bounded set of active context inclusion and exclusion policies.",
        ),
        OperationId::MediaCreate => presented(
            "Create Media Artifact",
            "Create metadata and storage references for a scoped media artifact.",
        ),
        OperationId::MediaList => presented(
            "List Media Artifacts",
            "List scoped media artifacts with bounded storage and transcription summaries.",
        ),
        OperationId::MediaInspect => presented(
            "Inspect Media Artifact",
            "Inspect one media artifact's metadata, storage, lifecycle, and transcription state.",
        ),
        OperationId::MediaArchive => presented(
            "Archive Media Artifact",
            "Archive one media artifact while preserving its lifecycle evidence.",
        ),
        OperationId::ImportHistoryRecord => presented(
            "Record Import History",
            "Record bounded lineage between imported session or resource references.",
        ),
        OperationId::ImportHistoryList => presented(
            "List Import History",
            "List scoped import-lineage records as bounded graph summaries.",
        ),
        OperationId::ImportHistoryInspect => presented(
            "Inspect Import History",
            "Inspect one import-lineage record and its evidence references.",
        ),
        OperationId::RepositoryTreeSnapshot => presented(
            "Snapshot Repository Tree",
            "Record content-free repository tree metadata, paths, references, and counts.",
        ),
        OperationId::RepositoryTreeList => presented(
            "List Repository Snapshots",
            "List content-free repository tree snapshots with bounded path previews.",
        ),
        OperationId::RepositoryTreeInspect => presented(
            "Inspect Repository Snapshot",
            "Inspect one content-free repository tree snapshot and its evidence.",
        ),
        OperationId::ImportPreviewRecord => presented(
            "Record Import Preview",
            "Record a content-free preview linking import history and repository metadata.",
        ),
        OperationId::ImportPreviewList => presented(
            "List Import Previews",
            "List content-free import previews with bounded counts and path summaries.",
        ),
        OperationId::ImportPreviewInspect => presented(
            "Inspect Import Preview",
            "Inspect one content-free import preview and its linked evidence.",
        ),
        OperationId::ProgramExecutionRecord => presented(
            "Record Program Execution",
            "Record content-free program execution metadata without launching a runtime.",
        ),
        OperationId::ProgramExecutionList => presented(
            "List Program Executions",
            "List content-free program execution records and lifecycle summaries.",
        ),
        OperationId::ProgramExecutionInspect => presented(
            "Inspect Program Execution",
            "Inspect one content-free program execution record and its evidence.",
        ),
        OperationId::PromptArtifactRecord => presented(
            "Record Prompt Artifact",
            "Record opt-in prompt artifact metadata without storing the raw prompt body.",
        ),
        OperationId::PromptArtifactList => presented(
            "List Prompt Artifacts",
            "List opt-in prompt artifacts with bounded metadata and retention state.",
        ),
        OperationId::PromptArtifactInspect => presented(
            "Inspect Prompt Artifact",
            "Inspect one prompt artifact's metadata, references, and retention evidence.",
        ),
        OperationId::UpdateDiagnosticRecord => presented(
            "Record Update Diagnostic",
            "Record signed-release and update-check metadata without installing an update.",
        ),
        OperationId::UpdateDiagnosticList => presented(
            "List Update Diagnostics",
            "List bounded update diagnostics and signature status summaries.",
        ),
        OperationId::UpdateDiagnosticInspect => presented(
            "Inspect Update Diagnostic",
            "Inspect one update diagnostic and its provenance and signature evidence.",
        ),
        OperationId::DeviceList => presented(
            "List Devices",
            "List registered devices with bounded delivery and lifecycle metadata.",
        ),
        OperationId::DeviceInspect => presented(
            "Inspect Device",
            "Inspect one registered device and its current delivery metadata.",
        ),
        OperationId::NotificationSend => presented(
            "Send Notification",
            "Send one scoped notification through the registered delivery path.",
        ),
        OperationId::NotificationList => presented(
            "List Notifications",
            "List scoped notifications with bounded delivery and read-state summaries.",
        ),
        OperationId::NotificationInspect => presented(
            "Inspect Notification",
            "Inspect one notification's content metadata, delivery, and read state.",
        ),
        OperationId::NotificationMarkRead => presented(
            "Mark Notification Read",
            "Mark one scoped notification as read after freshness checks.",
        ),
        OperationId::NotificationMarkAllRead => presented(
            "Mark All Notifications Read",
            "Mark all eligible notifications in the current scope as read.",
        ),
        OperationId::ProceduralDefinitionRecord => presented(
            "Record Procedural Definition",
            "Record metadata for a skill, rule, hook, or procedure without activating it.",
        ),
        OperationId::ProceduralStateList => presented(
            "List Procedural Definitions",
            "List scoped procedural definitions with bounded state and evaluation summaries.",
        ),
        OperationId::ProceduralStateInspect => presented(
            "Inspect Procedural Definition",
            "Inspect one procedural definition's metadata, state, and evaluation evidence.",
        ),
        OperationId::ProceduralActivationRequestRecord => presented(
            "Request Procedural Activation",
            "Record a review request to activate, deactivate, or roll back a procedure.",
        ),
        OperationId::ProceduralActivationRequestList => presented(
            "List Procedural Activation Requests",
            "List scoped procedural activation requests with bounded review summaries.",
        ),
        OperationId::ProceduralActivationRequestInspect => presented(
            "Inspect Procedural Activation Request",
            "Inspect one procedural activation request and its validation evidence.",
        ),
        OperationId::ProceduralActivationDecisionRecord => presented(
            "Record Procedural Activation Decision",
            "Record a review decision without activating or executing the procedure.",
        ),
        OperationId::ProceduralActivationDecisionList => presented(
            "List Procedural Activation Decisions",
            "List scoped procedural activation decisions with bounded evidence summaries.",
        ),
        OperationId::ProceduralActivationDecisionInspect => presented(
            "Inspect Procedural Activation Decision",
            "Inspect one procedural activation decision and its rollback evidence.",
        ),
        OperationId::ScheduleCreate => presented(
            "Create Schedule",
            "Create a durable schedule with bounded timing and target metadata.",
        ),
        OperationId::ScheduleList => presented(
            "List Schedules",
            "List scoped schedules with bounded timing and lifecycle summaries.",
        ),
        OperationId::ScheduleInspect => presented(
            "Inspect Schedule",
            "Inspect one schedule and its current timing and lifecycle state.",
        ),
        OperationId::ScheduleCancel => presented(
            "Cancel Schedule",
            "Cancel one active schedule after freshness and idempotency checks.",
        ),
        OperationId::ScheduleFireDue => presented(
            "Run Due Schedules",
            "Advance due schedules and record their bounded firing evidence.",
        ),
        OperationId::ToolSourceList => presented(
            "List Tool Sources",
            "List inert tool-source proposals without installing or running them.",
        ),
        OperationId::ToolSourceInspect => presented(
            "Inspect Tool Source",
            "Inspect one tool-source proposal or conformance report without activation.",
        ),
        OperationId::SubagentLaunch => presented(
            "Launch Subagent",
            "Launch a governed delegated task through the accepted supervised runtime.",
        ),
        OperationId::SubagentStatus => presented(
            "Inspect Subagent Status",
            "Inspect one delegated task and its supervised runtime status.",
        ),
        OperationId::SubagentResult => presented(
            "Review Subagent Result",
            "Return a reviewable result proposal without mutating the parent conversation.",
        ),
        OperationId::SubagentCancel => presented(
            "Cancel Subagent",
            "Cancel one nonterminal delegated task through its supervised runtime.",
        ),
        OperationId::SubagentTaskList => presented(
            "List Subagent Tasks",
            "List delegated task records with bounded lifecycle and handoff summaries.",
        ),
        OperationId::SubagentTaskInspect => presented(
            "Inspect Subagent Task",
            "Inspect one delegated task's lifecycle, runtime, and handoff evidence.",
        ),
        OperationId::WorkerPackageList => presented(
            "List Worker Packages",
            "List worker-package lifecycle records without installing or running packages.",
        ),
        OperationId::WorkerPackageInspect => presented(
            "Inspect Worker Package",
            "Inspect one worker-package lifecycle record and its bounded evidence.",
        ),
        OperationId::ModuleList => presented(
            "List Modules",
            "List registered modules through bounded provider-safe manifest summaries.",
        ),
        OperationId::ModuleInspect => presented(
            "Inspect Module",
            "Inspect one registered module's bounded manifest and lifecycle metadata.",
        ),
        OperationId::ModuleProposalRecord => presented(
            "Record Module Proposal",
            "Record inert module proposal metadata without installing or executing it.",
        ),
        OperationId::ModuleProposalList => presented(
            "List Module Proposals",
            "List inert module proposals with bounded status and evidence summaries.",
        ),
        OperationId::ModuleProposalInspect => presented(
            "Inspect Module Proposal",
            "Inspect one inert module proposal and its current evidence.",
        ),
        OperationId::ModuleValidationRecord => presented(
            "Record Module Validation",
            "Record module validation evidence without running or installing module code.",
        ),
        OperationId::ModuleValidationList => presented(
            "List Module Validations",
            "List module validation reports with bounded result summaries.",
        ),
        OperationId::ModuleValidationInspect => presented(
            "Inspect Module Validation",
            "Inspect one module validation report and its evidence.",
        ),
        OperationId::ModuleInstallRequestRecord => presented(
            "Request Module Installation",
            "Record a review request to install a validated module without installing it.",
        ),
        OperationId::ModuleInstallRequestList => presented(
            "List Module Installation Requests",
            "List module installation requests with bounded review state.",
        ),
        OperationId::ModuleInstallRequestInspect => presented(
            "Inspect Module Installation Request",
            "Inspect one module installation request and its validation evidence.",
        ),
        OperationId::ModuleInstallDecisionRecord => presented(
            "Record Module Installation Decision",
            "Record an installation review decision without installing or enabling the module.",
        ),
        OperationId::ModuleInstallDecisionList => presented(
            "List Module Installation Decisions",
            "List module installation decisions with bounded approval summaries.",
        ),
        OperationId::ModuleInstallDecisionInspect => presented(
            "Inspect Module Installation Decision",
            "Inspect one installation decision and its rollback evidence.",
        ),
        OperationId::ModuleDependencyRequestRecord => presented(
            "Request Module Dependency",
            "Record a module dependency review request without restoring dependencies.",
        ),
        OperationId::ModuleDependencyRequestList => presented(
            "List Module Dependency Requests",
            "List module dependency requests with bounded policy summaries.",
        ),
        OperationId::ModuleDependencyRequestInspect => presented(
            "Inspect Module Dependency Request",
            "Inspect one module dependency request and its policy evidence.",
        ),
        OperationId::ModuleDependencyDecisionRecord => presented(
            "Record Module Dependency Decision",
            "Record a dependency review decision without changing package state.",
        ),
        OperationId::ModuleDependencyDecisionList => presented(
            "List Module Dependency Decisions",
            "List module dependency decisions with bounded approval summaries.",
        ),
        OperationId::ModuleDependencyDecisionInspect => presented(
            "Inspect Module Dependency Decision",
            "Inspect one dependency decision and its policy evidence.",
        ),
        OperationId::ModuleDependencyPolicyActivate => presented(
            "Activate Module Dependency Policy",
            "Activate approved dependency policy metadata without restoring packages.",
        ),
        OperationId::ModuleDependencyPolicyList => presented(
            "List Module Dependency Policies",
            "List active module dependency policies with bounded evidence summaries.",
        ),
        OperationId::ModuleDependencyPolicyInspect => presented(
            "Inspect Module Dependency Policy",
            "Inspect one module dependency policy and its approval evidence.",
        ),
        OperationId::CapabilityBindingRequestRecord => presented(
            "Request Capability Binding",
            "Record a governed proposal to extend, shadow, or replace an operation.",
        ),
        OperationId::CapabilityBindingRequestList => presented(
            "List Capability Binding Requests",
            "List capability binding proposals with bounded governance summaries.",
        ),
        OperationId::CapabilityBindingRequestInspect => presented(
            "Inspect Capability Binding Request",
            "Inspect one capability binding proposal and its requirements.",
        ),
        OperationId::CapabilityBindingDecisionRecord => presented(
            "Record Capability Binding Decision",
            "Record a governance decision for one capability binding proposal.",
        ),
        OperationId::CapabilityBindingDecisionList => presented(
            "List Capability Binding Decisions",
            "List capability binding decisions with bounded policy summaries.",
        ),
        OperationId::CapabilityBindingDecisionInspect => presented(
            "Inspect Capability Binding Decision",
            "Inspect one capability binding decision and its governance evidence.",
        ),
        OperationId::CapabilityBindingPolicyActivate => presented(
            "Activate Capability Binding Policy",
            "Activate approved binding policy metadata without changing runtime routing.",
        ),
        OperationId::CapabilityBindingPolicyList => presented(
            "List Capability Binding Policies",
            "List active capability binding policies with bounded evidence summaries.",
        ),
        OperationId::CapabilityBindingPolicyInspect => presented(
            "Inspect Capability Binding Policy",
            "Inspect one capability binding policy and its rollback controls.",
        ),
        OperationId::CapabilityBindingCockpitOverview => presented(
            "View Capability Dashboard",
            "Show operation ownership, replacement readiness, and route evidence for the current scope.",
        ),
        OperationId::CapabilityShadowTrialRequestRecord => presented(
            "Request Capability Shadow Trial",
            "Record a governed request to compare built-in and candidate behavior.",
        ),
        OperationId::CapabilityShadowTrialDecisionRecord => presented(
            "Record Shadow Trial Decision",
            "Record approval, rejection, disablement, or cancellation of a shadow trial.",
        ),
        OperationId::CapabilityShadowTrialRunRecord => presented(
            "Record Shadow Trial Run",
            "Compare bounded built-in and candidate projections without changing live routing.",
        ),
        OperationId::CapabilityShadowTrialEvidenceInspect => presented(
            "Inspect Shadow Trial Evidence",
            "Inspect one shadow comparison and its rollback and disable controls.",
        ),
        OperationId::CapabilityReplacementCandidateRecord => presented(
            "Record Replacement Candidate",
            "Record a governed operation replacement candidate and its safety evidence.",
        ),
        OperationId::CapabilityReplacementCandidateList => presented(
            "List Replacement Candidates",
            "List operation replacement candidates with bounded lifecycle summaries.",
        ),
        OperationId::CapabilityReplacementCandidateInspect => presented(
            "Inspect Replacement Candidate",
            "Inspect one operation replacement candidate and its rollback evidence.",
        ),
        OperationId::CapabilityRouteBindingRecord => presented(
            "Record Capability Route",
            "Record a governed route between an operation and a validated candidate.",
        ),
        OperationId::CapabilityRouteBindingList => presented(
            "List Capability Routes",
            "List governed operation routes with bounded readiness summaries.",
        ),
        OperationId::CapabilityRouteBindingInspect => presented(
            "Inspect Capability Route",
            "Inspect one governed operation route and its activation gates.",
        ),
        OperationId::CapabilityRouteActivate => presented(
            "Activate Capability Route",
            "Activate a governed replacement route after approval and rollback checks.",
        ),
        OperationId::CapabilityRouteDisable => presented(
            "Disable Capability Route",
            "Disable an active replacement route and restore built-in ownership.",
        ),
        OperationId::CapabilityRouteRollback => presented(
            "Roll Back Capability Route",
            "Record rollback of an active route and restore built-in ownership.",
        ),
        OperationId::CapabilityRouteEventList => presented(
            "List Capability Route Events",
            "List bounded activation, invocation, disablement, and rollback history.",
        ),
        OperationId::CapabilityRouteEventInspect => presented(
            "Inspect Capability Route Event",
            "Inspect one route event and its bounded outcome evidence.",
        ),
        OperationId::ModuleLifecycleRequest => presented(
            "Request Module Lifecycle Change",
            "Request a governed module enable, disable, quarantine, or rollback transition.",
        ),
        OperationId::ModuleLifecycleDecision => presented(
            "Decide Module Lifecycle Change",
            "Apply an approved module lifecycle transition without running module code.",
        ),
        OperationId::ModuleLifecycleList => presented(
            "List Module Lifecycle States",
            "List module lifecycle records with bounded authorization and rollback summaries.",
        ),
        OperationId::ModuleLifecycleInspect => presented(
            "Inspect Module Lifecycle",
            "Inspect one module lifecycle record and its authorization evidence.",
        ),
        OperationId::ModuleProgramExecutionStart => presented(
            "Start Module Program",
            "Start a supervised module-owned job through an authorized runtime.",
        ),
        OperationId::ModuleProgramExecutionStatus => presented(
            "Inspect Module Program Status",
            "Inspect a delegated module job through bounded runtime and output references.",
        ),
        OperationId::ModuleProgramExecutionCancel => presented(
            "Cancel Module Program",
            "Request cancellation of one delegated module job.",
        ),
        OperationId::ModuleProgramExecutionCleanup => presented(
            "Clean Up Module Program",
            "Archive one terminal delegated module job after freshness checks.",
        ),
        OperationId::ModuleRuntimeRequest => presented(
            "Request Module Runtime",
            "Record a supervised runtime envelope for an enabled module.",
        ),
        OperationId::ModuleRuntimeList => presented(
            "List Module Runtimes",
            "List supervised module runtimes with bounded lifecycle summaries.",
        ),
        OperationId::ModuleRuntimeInspect => presented(
            "Inspect Module Runtime",
            "Inspect one supervised module runtime and its authorization evidence.",
        ),
        OperationId::ModuleRuntimeCancel => presented(
            "Cancel Module Runtime",
            "Record cancellation of one active supervised module runtime.",
        ),
        OperationId::WebFetch => presented(
            "Fetch Web Source",
            "Fetch one explicit URL with declared network and robots-policy authority.",
        ),
        OperationId::WebRobotsCheck => presented(
            "Check Web Robots Policy",
            "Check one origin's robots policy for an explicit requested URL.",
        ),
        OperationId::WebSourceList => presented(
            "List Web Sources",
            "List citation-ready web source records without network access.",
        ),
        OperationId::WebSourceInspect => presented(
            "Inspect Web Source",
            "Inspect one citation-ready web source and its bounded snippet evidence.",
        ),
        OperationId::WebSourceArchive => presented(
            "Archive Web Source",
            "Archive one web source while preserving its provenance evidence.",
        ),
        OperationId::WebResearchRequestRecord => presented(
            "Record Web Research Request",
            "Record bounded web research intent and policy metadata without fetching sources.",
        ),
        OperationId::WebResearchRequestList => presented(
            "List Web Research Requests",
            "List scoped web research requests without network or browser activity.",
        ),
        OperationId::WebResearchRequestInspect => presented(
            "Inspect Web Research Request",
            "Inspect one web research request and its bounded policy references.",
        ),
        OperationId::WebResearchReviewRecord => presented(
            "Record Web Research Review",
            "Record a bounded review linked to one web research request.",
        ),
        OperationId::WebResearchReviewList => presented(
            "List Web Research Reviews",
            "List scoped web research reviews without network access.",
        ),
        OperationId::WebResearchReviewInspect => presented(
            "Inspect Web Research Review",
            "Inspect one web research review and its evidence references.",
        ),
        OperationId::WebResearchSourceRecord => presented(
            "Record Web Research Source",
            "Record bounded citation metadata linked to a research request or review.",
        ),
        OperationId::WebResearchSourceList => presented(
            "List Web Research Sources",
            "List bounded citation artifacts linked to scoped web research.",
        ),
        OperationId::WebResearchSourceInspect => presented(
            "Inspect Web Research Source",
            "Inspect one bounded research source and its citation references.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_operation_has_friendly_concise_presentation_metadata() {
        for operation_name in OperationId::ALL_NAMES {
            let metadata = operation_presentation(operation_name)
                .unwrap_or_else(|| panic!("missing presentation metadata for {operation_name}"));
            assert!(!metadata.display_name.trim().is_empty(), "{operation_name}");
            assert!(!metadata.description.trim().is_empty(), "{operation_name}");
            assert!(
                !metadata.display_name.contains(['_', ':']),
                "{operation_name} leaked raw separators into {}",
                metadata.display_name
            );
            assert!(
                !metadata.description.contains(['_', ':']),
                "{operation_name} leaked raw separators into {}",
                metadata.description
            );
            assert!(
                metadata.description.len() <= 180,
                "{operation_name} description is too long: {}",
                metadata.description
            );
        }
        assert!(operation_presentation("future_unknown_operation").is_none());
    }

    #[test]
    fn representative_provider_visible_presentations_are_stable() {
        let cases = [
            (
                OperationId::ProcessRun,
                "Run Process",
                "Run a bounded local command with timeout, output, and no-network enforcement.",
            ),
            (
                OperationId::GoalCreate,
                "Create Goal",
                "Create a durable scoped goal with lifecycle and evidence references.",
            ),
            (
                OperationId::ModuleLifecycleRequest,
                "Request Module Lifecycle Change",
                "Request a governed module enable, disable, quarantine, or rollback transition.",
            ),
            (
                OperationId::CapabilityBindingCockpitOverview,
                "View Capability Dashboard",
                "Show operation ownership, replacement readiness, and route evidence for the current scope.",
            ),
        ];

        for (operation, display_name, description) in cases {
            assert_eq!(
                operation_presentation(operation.as_str()),
                Some(OperationPresentation {
                    display_name,
                    description,
                })
            );
        }
    }
}
