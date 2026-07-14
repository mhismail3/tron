//! Governance and supervised-runtime provider-visible presentation literals.

#[cfg(test)]
use super::PresentationFamily;
use super::{OperationPresentation, PresentationEntry};

const fn presented(display_name: &'static str, description: &'static str) -> PresentationEntry {
    PresentationEntry {
        presentation: OperationPresentation {
            display_name,
            description,
        },
        #[cfg(test)]
        family: PresentationFamily::Governance,
    }
}

pub(super) const PROCEDURAL_DEFINITION_RECORD: PresentationEntry = presented(
    "Record Procedural Definition",
    "Record metadata for a skill, rule, hook, or procedure without activating it.",
);
pub(super) const PROCEDURAL_STATE_LIST: PresentationEntry = presented(
    "List Procedural Definitions",
    "List scoped procedural definitions with bounded state and evaluation summaries.",
);
pub(super) const PROCEDURAL_STATE_INSPECT: PresentationEntry = presented(
    "Inspect Procedural Definition",
    "Inspect one procedural definition's metadata, state, and evaluation evidence.",
);
pub(super) const PROCEDURAL_ACTIVATION_REQUEST_RECORD: PresentationEntry = presented(
    "Request Procedural Activation",
    "Record a review request to activate, deactivate, or roll back a procedure.",
);
pub(super) const PROCEDURAL_ACTIVATION_REQUEST_LIST: PresentationEntry = presented(
    "List Procedural Activation Requests",
    "List scoped procedural activation requests with bounded review summaries.",
);
pub(super) const PROCEDURAL_ACTIVATION_REQUEST_INSPECT: PresentationEntry = presented(
    "Inspect Procedural Activation Request",
    "Inspect one procedural activation request and its validation evidence.",
);
pub(super) const PROCEDURAL_ACTIVATION_DECISION_RECORD: PresentationEntry = presented(
    "Record Procedural Activation Decision",
    "Record a review decision without activating or executing the procedure.",
);
pub(super) const PROCEDURAL_ACTIVATION_DECISION_LIST: PresentationEntry = presented(
    "List Procedural Activation Decisions",
    "List scoped procedural activation decisions with bounded evidence summaries.",
);
pub(super) const PROCEDURAL_ACTIVATION_DECISION_INSPECT: PresentationEntry = presented(
    "Inspect Procedural Activation Decision",
    "Inspect one procedural activation decision and its rollback evidence.",
);
pub(super) const SCHEDULE_CREATE: PresentationEntry = presented(
    "Create Schedule",
    "Create a durable schedule with bounded timing and target metadata.",
);
pub(super) const SCHEDULE_LIST: PresentationEntry = presented(
    "List Schedules",
    "List scoped schedules with bounded timing and lifecycle summaries.",
);
pub(super) const SCHEDULE_INSPECT: PresentationEntry = presented(
    "Inspect Schedule",
    "Inspect one schedule and its current timing and lifecycle state.",
);
pub(super) const SCHEDULE_CANCEL: PresentationEntry = presented(
    "Cancel Schedule",
    "Cancel one active schedule after freshness and idempotency checks.",
);
pub(super) const SCHEDULE_FIRE_DUE: PresentationEntry = presented(
    "Run Due Schedules",
    "Advance due schedules and record their bounded firing evidence.",
);
pub(super) const TOOL_SOURCE_LIST: PresentationEntry = presented(
    "List Tool Sources",
    "List inert tool-source proposals without installing or running them.",
);
pub(super) const TOOL_SOURCE_INSPECT: PresentationEntry = presented(
    "Inspect Tool Source",
    "Inspect one tool-source proposal or conformance report without activation.",
);
pub(super) const SUBAGENT_LAUNCH: PresentationEntry = presented(
    "Launch Subagent",
    "Launch a governed delegated task through the accepted supervised runtime.",
);
pub(super) const SUBAGENT_STATUS: PresentationEntry = presented(
    "Inspect Subagent Status",
    "Inspect one delegated task and its supervised runtime status.",
);
pub(super) const SUBAGENT_RESULT: PresentationEntry = presented(
    "Review Subagent Result",
    "Return a reviewable result proposal without mutating the parent conversation.",
);
pub(super) const SUBAGENT_CANCEL: PresentationEntry = presented(
    "Cancel Subagent",
    "Cancel one nonterminal delegated task through its supervised runtime.",
);
pub(super) const SUBAGENT_TASK_LIST: PresentationEntry = presented(
    "List Subagent Tasks",
    "List delegated task records with bounded lifecycle and handoff summaries.",
);
pub(super) const SUBAGENT_TASK_INSPECT: PresentationEntry = presented(
    "Inspect Subagent Task",
    "Inspect one delegated task's lifecycle, runtime, and handoff evidence.",
);
pub(super) const WORKER_PACKAGE_LIST: PresentationEntry = presented(
    "List Worker Packages",
    "List worker-package lifecycle records without installing or running packages.",
);
pub(super) const WORKER_PACKAGE_INSPECT: PresentationEntry = presented(
    "Inspect Worker Package",
    "Inspect one worker-package lifecycle record and its bounded evidence.",
);
pub(super) const MODULE_LIST: PresentationEntry = presented(
    "List Modules",
    "List registered modules through bounded provider-safe manifest summaries.",
);
pub(super) const MODULE_INSPECT: PresentationEntry = presented(
    "Inspect Module",
    "Inspect one registered module's bounded manifest and lifecycle metadata.",
);
pub(super) const MODULE_PROPOSAL_RECORD: PresentationEntry = presented(
    "Record Module Proposal",
    "Record inert module proposal metadata without installing or executing it.",
);
pub(super) const MODULE_PROPOSAL_LIST: PresentationEntry = presented(
    "List Module Proposals",
    "List inert module proposals with bounded status and evidence summaries.",
);
pub(super) const MODULE_PROPOSAL_INSPECT: PresentationEntry = presented(
    "Inspect Module Proposal",
    "Inspect one inert module proposal and its current evidence.",
);
pub(super) const MODULE_VALIDATION_RECORD: PresentationEntry = presented(
    "Record Module Validation",
    "Record module validation evidence without running or installing module code.",
);
pub(super) const MODULE_VALIDATION_LIST: PresentationEntry = presented(
    "List Module Validations",
    "List module validation reports with bounded result summaries.",
);
pub(super) const MODULE_VALIDATION_INSPECT: PresentationEntry = presented(
    "Inspect Module Validation",
    "Inspect one module validation report and its evidence.",
);
pub(super) const MODULE_INSTALL_REQUEST_RECORD: PresentationEntry = presented(
    "Request Module Installation",
    "Record a review request to install a validated module without installing it.",
);
pub(super) const MODULE_INSTALL_REQUEST_LIST: PresentationEntry = presented(
    "List Module Installation Requests",
    "List module installation requests with bounded review state.",
);
pub(super) const MODULE_INSTALL_REQUEST_INSPECT: PresentationEntry = presented(
    "Inspect Module Installation Request",
    "Inspect one module installation request and its validation evidence.",
);
pub(super) const MODULE_INSTALL_DECISION_RECORD: PresentationEntry = presented(
    "Record Module Installation Decision",
    "Record an installation review decision without installing or enabling the module.",
);
pub(super) const MODULE_INSTALL_DECISION_LIST: PresentationEntry = presented(
    "List Module Installation Decisions",
    "List module installation decisions with bounded approval summaries.",
);
pub(super) const MODULE_INSTALL_DECISION_INSPECT: PresentationEntry = presented(
    "Inspect Module Installation Decision",
    "Inspect one installation decision and its rollback evidence.",
);
pub(super) const MODULE_DEPENDENCY_REQUEST_RECORD: PresentationEntry = presented(
    "Request Module Dependency",
    "Record a module dependency review request without restoring dependencies.",
);
pub(super) const MODULE_DEPENDENCY_REQUEST_LIST: PresentationEntry = presented(
    "List Module Dependency Requests",
    "List module dependency requests with bounded policy summaries.",
);
pub(super) const MODULE_DEPENDENCY_REQUEST_INSPECT: PresentationEntry = presented(
    "Inspect Module Dependency Request",
    "Inspect one module dependency request and its policy evidence.",
);
pub(super) const MODULE_DEPENDENCY_DECISION_RECORD: PresentationEntry = presented(
    "Record Module Dependency Decision",
    "Record a dependency review decision without changing package state.",
);
pub(super) const MODULE_DEPENDENCY_DECISION_LIST: PresentationEntry = presented(
    "List Module Dependency Decisions",
    "List module dependency decisions with bounded approval summaries.",
);
pub(super) const MODULE_DEPENDENCY_DECISION_INSPECT: PresentationEntry = presented(
    "Inspect Module Dependency Decision",
    "Inspect one dependency decision and its policy evidence.",
);
pub(super) const MODULE_DEPENDENCY_POLICY_ACTIVATE: PresentationEntry = presented(
    "Activate Module Dependency Policy",
    "Activate approved dependency policy metadata without restoring packages.",
);
pub(super) const MODULE_DEPENDENCY_POLICY_LIST: PresentationEntry = presented(
    "List Module Dependency Policies",
    "List active module dependency policies with bounded evidence summaries.",
);
pub(super) const MODULE_DEPENDENCY_POLICY_INSPECT: PresentationEntry = presented(
    "Inspect Module Dependency Policy",
    "Inspect one module dependency policy and its approval evidence.",
);
pub(super) const MODULE_LIFECYCLE_REQUEST: PresentationEntry = presented(
    "Request Module Lifecycle Change",
    "Request a governed module enable, disable, quarantine, or rollback transition.",
);
pub(super) const MODULE_LIFECYCLE_DECISION: PresentationEntry = presented(
    "Decide Module Lifecycle Change",
    "Apply an approved module lifecycle transition without running module code.",
);
pub(super) const MODULE_LIFECYCLE_LIST: PresentationEntry = presented(
    "List Module Lifecycle States",
    "List module lifecycle records with bounded authorization and rollback summaries.",
);
pub(super) const MODULE_LIFECYCLE_INSPECT: PresentationEntry = presented(
    "Inspect Module Lifecycle",
    "Inspect one module lifecycle record and its authorization evidence.",
);
pub(super) const MODULE_PROGRAM_EXECUTION_START: PresentationEntry = presented(
    "Start Module Program",
    "Start a supervised module-owned job through an authorized runtime.",
);
pub(super) const MODULE_PROGRAM_EXECUTION_STATUS: PresentationEntry = presented(
    "Inspect Module Program Status",
    "Inspect a delegated module job through bounded runtime and output references.",
);
pub(super) const MODULE_PROGRAM_EXECUTION_CANCEL: PresentationEntry = presented(
    "Cancel Module Program",
    "Request cancellation of one delegated module job.",
);
pub(super) const MODULE_PROGRAM_EXECUTION_CLEANUP: PresentationEntry = presented(
    "Clean Up Module Program",
    "Archive one terminal delegated module job after freshness checks.",
);
pub(super) const MODULE_RUNTIME_REQUEST: PresentationEntry = presented(
    "Request Module Runtime",
    "Record a supervised runtime envelope for an enabled module.",
);
pub(super) const MODULE_RUNTIME_LIST: PresentationEntry = presented(
    "List Module Runtimes",
    "List supervised module runtimes with bounded lifecycle summaries.",
);
pub(super) const MODULE_RUNTIME_INSPECT: PresentationEntry = presented(
    "Inspect Module Runtime",
    "Inspect one supervised module runtime and its authorization evidence.",
);
pub(super) const MODULE_RUNTIME_CANCEL: PresentationEntry = presented(
    "Cancel Module Runtime",
    "Record cancellation of one active supervised module runtime.",
);
