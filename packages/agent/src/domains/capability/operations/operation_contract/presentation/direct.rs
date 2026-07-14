//! Direct engine and adapter provider-visible presentation literals.

use super::OperationPresentation;

const fn presented(display_name: &'static str, description: &'static str) -> OperationPresentation {
    OperationPresentation {
        display_name,
        description,
    }
}

pub(super) const OBSERVE: OperationPresentation = presented(
    "Record Observation",
    "Add a bounded observation to the current assistant-visible work stream.",
);
pub(super) const STATE_GET: OperationPresentation = presented(
    "Get State",
    "Read one value from engine-owned state in the current scope.",
);
pub(super) const STATE_SET: OperationPresentation = presented(
    "Update State",
    "Write one value to engine-owned state in the current scope.",
);
pub(super) const STATE_LIST: OperationPresentation = presented(
    "List State",
    "List engine-owned state entries for a scope and namespace.",
);
pub(super) const FILESYSTEM_READ: OperationPresentation = presented(
    "Read File",
    "Read a bounded text preview beneath the trusted workspace root.",
);
pub(super) const FILESYSTEM_LIST: OperationPresentation = presented(
    "List Files",
    "List bounded directory entries beneath the trusted workspace root.",
);
pub(super) const FILESYSTEM_FIND: OperationPresentation = presented(
    "Find Files",
    "Find bounded paths by name without following symbolic links.",
);
pub(super) const FILESYSTEM_GLOB: OperationPresentation = presented(
    "Match Files by Pattern",
    "Find bounded paths that match a workspace-relative glob pattern.",
);
pub(super) const FILESYSTEM_SEARCH_TEXT: OperationPresentation = presented(
    "Search File Text",
    "Search bounded text previews while skipping binary file content.",
);
pub(super) const FILESYSTEM_DIFF: OperationPresentation = presented(
    "Preview File Changes",
    "Compare current file content with a proposed bounded text change.",
);
pub(super) const FILESYSTEM_WRITE: OperationPresentation = presented(
    "Write File",
    "Preview or commit a guarded file write with verifiable evidence.",
);
pub(super) const FILESYSTEM_EDIT: OperationPresentation = presented(
    "Edit File",
    "Preview or commit one exact guarded text replacement.",
);
pub(super) const FILESYSTEM_APPLY_PATCH: OperationPresentation = presented(
    "Apply File Patch",
    "Apply an exact guarded text patch with bounded evidence.",
);
pub(super) const GIT_STATUS: OperationPresentation = presented(
    "Inspect Git Status",
    "Inspect branch, upstream, and bounded working-tree status without changing the repository.",
);
pub(super) const GIT_DIFF: OperationPresentation = presented(
    "Inspect Git Changes",
    "Read bounded staged and unstaged change evidence without running external helpers.",
);
pub(super) const GIT_BRANCH_INVENTORY: OperationPresentation = presented(
    "List Git Branches",
    "List local branches, revisions, upstreams, and ahead or behind status.",
);
pub(super) const GIT_STAGE: OperationPresentation = presented(
    "Stage File",
    "Stage one explicit workspace-relative path after repository freshness checks.",
);
pub(super) const GIT_UNSTAGE: OperationPresentation = presented(
    "Unstage File",
    "Remove one explicit workspace-relative path from the Git index.",
);
pub(super) const GIT_COMMIT: OperationPresentation = presented(
    "Create Git Commit",
    "Create one guarded commit from the already staged Git index.",
);
pub(super) const GIT_BRANCH_START: OperationPresentation = presented(
    "Start Git Branch",
    "Create and select a new local branch without changing workspace content.",
);
pub(super) const PROCESS_RUN: OperationPresentation = presented(
    "Run Process",
    "Run a bounded local command with timeout, output, and no-network enforcement.",
);
pub(super) const JOB_START: OperationPresentation = presented(
    "Start Job",
    "Start a supervised durable command job with bounded output and lifecycle evidence.",
);
pub(super) const JOB_STATUS: OperationPresentation = presented(
    "Inspect Job Status",
    "Inspect a durable job's redacted lifecycle, timing, and output references.",
);
pub(super) const JOB_LIST: OperationPresentation = presented(
    "List Jobs",
    "List durable jobs in the current scope with bounded lifecycle summaries.",
);
pub(super) const JOB_LOG: OperationPresentation = presented(
    "Read Job Output",
    "Read bounded standard-output and standard-error previews for one durable job.",
);
pub(super) const JOB_CANCEL: OperationPresentation = presented(
    "Cancel Job",
    "Request guarded cancellation of a running durable job.",
);
pub(super) const TRACE_LIST: OperationPresentation = presented(
    "List Execution Traces",
    "List bounded provider-safe execution traces for the current session.",
);
pub(super) const TRACE_GET: OperationPresentation = presented(
    "Inspect Execution Trace",
    "Inspect one provider-safe execution trace by its exact record reference.",
);
pub(super) const LOG_RECENT: OperationPresentation = presented(
    "Read Recent Logs",
    "Read bounded recent engine log evidence with optional trace filtering.",
);
pub(super) const REPLAY_MANIFEST: OperationPresentation = presented(
    "Export Replay Manifest",
    "Export the current session's replay hashes and cross-record references.",
);
pub(super) const CATALOG_SEARCH: OperationPresentation = presented(
    "Search Capability Catalog",
    "Find visible operations and engine functions without invoking them.",
);
pub(super) const CATALOG_INSPECT: OperationPresentation = presented(
    "Inspect Capability Contract",
    "Inspect one operation, function, worker, or trigger contract without invoking it.",
);
pub(super) const CATALOG_CONFORMANCE: OperationPresentation = presented(
    "Verify Capability Catalog",
    "Record a catalog conformance report and its verification evidence.",
);
pub(super) const REPOSITORY_TREE_SNAPSHOT: OperationPresentation = presented(
    "Snapshot Repository Tree",
    "Record content-free repository tree metadata, paths, references, and counts.",
);
pub(super) const REPOSITORY_TREE_LIST: OperationPresentation = presented(
    "List Repository Snapshots",
    "List content-free repository tree snapshots with bounded path previews.",
);
pub(super) const REPOSITORY_TREE_INSPECT: OperationPresentation = presented(
    "Inspect Repository Snapshot",
    "Inspect one content-free repository tree snapshot and its evidence.",
);
pub(super) const WEB_FETCH: OperationPresentation = presented(
    "Fetch Web Source",
    "Fetch one explicit URL with declared network and robots-policy authority.",
);
pub(super) const WEB_ROBOTS_CHECK: OperationPresentation = presented(
    "Check Web Robots Policy",
    "Check one origin's robots policy for an explicit requested URL.",
);
pub(super) const WEB_SOURCE_LIST: OperationPresentation = presented(
    "List Web Sources",
    "List citation-ready web source records without network access.",
);
pub(super) const WEB_SOURCE_INSPECT: OperationPresentation = presented(
    "Inspect Web Source",
    "Inspect one citation-ready web source and its bounded snippet evidence.",
);
pub(super) const WEB_SOURCE_ARCHIVE: OperationPresentation = presented(
    "Archive Web Source",
    "Archive one web source while preserving its provenance evidence.",
);
