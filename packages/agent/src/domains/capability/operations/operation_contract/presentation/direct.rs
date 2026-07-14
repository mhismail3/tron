//! Direct engine and adapter provider-visible presentation literals.

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
        family: PresentationFamily::Direct,
    }
}

pub(super) const OBSERVE: PresentationEntry = presented(
    "Record Observation",
    "Add a bounded observation to the current assistant-visible work stream.",
);
pub(super) const STATE_GET: PresentationEntry = presented(
    "Get State",
    "Read one value from engine-owned state in the current scope.",
);
pub(super) const STATE_SET: PresentationEntry = presented(
    "Update State",
    "Write one value to engine-owned state in the current scope.",
);
pub(super) const STATE_LIST: PresentationEntry = presented(
    "List State",
    "List engine-owned state entries for a scope and namespace.",
);
pub(super) const FILESYSTEM_READ: PresentationEntry = presented(
    "Read File",
    "Read a bounded text preview beneath the trusted workspace root.",
);
pub(super) const FILESYSTEM_LIST: PresentationEntry = presented(
    "List Files",
    "List bounded directory entries beneath the trusted workspace root.",
);
pub(super) const FILESYSTEM_FIND: PresentationEntry = presented(
    "Find Files",
    "Find bounded paths by name without following symbolic links.",
);
pub(super) const FILESYSTEM_GLOB: PresentationEntry = presented(
    "Match Files by Pattern",
    "Find bounded paths that match a workspace-relative glob pattern.",
);
pub(super) const FILESYSTEM_SEARCH_TEXT: PresentationEntry = presented(
    "Search File Text",
    "Search bounded text previews while skipping binary file content.",
);
pub(super) const FILESYSTEM_DIFF: PresentationEntry = presented(
    "Preview File Changes",
    "Compare current file content with a proposed bounded text change.",
);
pub(super) const FILESYSTEM_WRITE: PresentationEntry = presented(
    "Write File",
    "Preview or commit a guarded file write with verifiable evidence.",
);
pub(super) const FILESYSTEM_EDIT: PresentationEntry = presented(
    "Edit File",
    "Preview or commit one exact guarded text replacement.",
);
pub(super) const FILESYSTEM_APPLY_PATCH: PresentationEntry = presented(
    "Apply File Patch",
    "Apply an exact guarded text patch with bounded evidence.",
);
pub(super) const GIT_STATUS: PresentationEntry = presented(
    "Inspect Git Status",
    "Inspect branch, upstream, and bounded working-tree status without changing the repository.",
);
pub(super) const GIT_DIFF: PresentationEntry = presented(
    "Inspect Git Changes",
    "Read bounded staged and unstaged change evidence without running external helpers.",
);
pub(super) const GIT_BRANCH_INVENTORY: PresentationEntry = presented(
    "List Git Branches",
    "List local branches, revisions, upstreams, and ahead or behind status.",
);
pub(super) const GIT_STAGE: PresentationEntry = presented(
    "Stage File",
    "Stage one explicit workspace-relative path after repository freshness checks.",
);
pub(super) const GIT_UNSTAGE: PresentationEntry = presented(
    "Unstage File",
    "Remove one explicit workspace-relative path from the Git index.",
);
pub(super) const GIT_COMMIT: PresentationEntry = presented(
    "Create Git Commit",
    "Create one guarded commit from the already staged Git index.",
);
pub(super) const GIT_BRANCH_START: PresentationEntry = presented(
    "Start Git Branch",
    "Create and select a new local branch without changing workspace content.",
);
pub(super) const PROCESS_RUN: PresentationEntry = presented(
    "Run Process",
    "Run a bounded local command with timeout, output, and no-network enforcement.",
);
pub(super) const JOB_START: PresentationEntry = presented(
    "Start Job",
    "Start a supervised durable command job with bounded output and lifecycle evidence.",
);
pub(super) const JOB_STATUS: PresentationEntry = presented(
    "Inspect Job Status",
    "Inspect a durable job's redacted lifecycle, timing, and output references.",
);
pub(super) const JOB_LIST: PresentationEntry = presented(
    "List Jobs",
    "List durable jobs in the current scope with bounded lifecycle summaries.",
);
pub(super) const JOB_LOG: PresentationEntry = presented(
    "Read Job Output",
    "Read bounded standard-output and standard-error previews for one durable job.",
);
pub(super) const JOB_CANCEL: PresentationEntry = presented(
    "Cancel Job",
    "Request guarded cancellation of a running durable job.",
);
pub(super) const TRACE_LIST: PresentationEntry = presented(
    "List Execution Traces",
    "List bounded provider-safe execution traces for the current session.",
);
pub(super) const TRACE_GET: PresentationEntry = presented(
    "Inspect Execution Trace",
    "Inspect one provider-safe execution trace by its exact record reference.",
);
pub(super) const LOG_RECENT: PresentationEntry = presented(
    "Read Recent Logs",
    "Read bounded recent engine log evidence with optional trace filtering.",
);
pub(super) const REPLAY_MANIFEST: PresentationEntry = presented(
    "Export Replay Manifest",
    "Export the current session's replay hashes and cross-record references.",
);
pub(super) const CATALOG_SEARCH: PresentationEntry = presented(
    "Search Capability Catalog",
    "Find visible operations and engine functions without invoking them.",
);
pub(super) const CATALOG_INSPECT: PresentationEntry = presented(
    "Inspect Capability Contract",
    "Inspect one operation, function, worker, or trigger contract without invoking it.",
);
pub(super) const CATALOG_CONFORMANCE: PresentationEntry = presented(
    "Verify Capability Catalog",
    "Record a catalog conformance report and its verification evidence.",
);
pub(super) const REPOSITORY_TREE_SNAPSHOT: PresentationEntry = presented(
    "Snapshot Repository Tree",
    "Record content-free repository tree metadata, paths, references, and counts.",
);
pub(super) const REPOSITORY_TREE_LIST: PresentationEntry = presented(
    "List Repository Snapshots",
    "List content-free repository tree snapshots with bounded path previews.",
);
pub(super) const REPOSITORY_TREE_INSPECT: PresentationEntry = presented(
    "Inspect Repository Snapshot",
    "Inspect one content-free repository tree snapshot and its evidence.",
);
pub(super) const WEB_FETCH: PresentationEntry = presented(
    "Fetch Web Source",
    "Fetch one explicit URL with declared network and robots-policy authority.",
);
pub(super) const WEB_ROBOTS_CHECK: PresentationEntry = presented(
    "Check Web Robots Policy",
    "Check one origin's robots policy for an explicit requested URL.",
);
pub(super) const WEB_SOURCE_LIST: PresentationEntry = presented(
    "List Web Sources",
    "List citation-ready web source records without network access.",
);
pub(super) const WEB_SOURCE_INSPECT: PresentationEntry = presented(
    "Inspect Web Source",
    "Inspect one citation-ready web source and its bounded snippet evidence.",
);
pub(super) const WEB_SOURCE_ARCHIVE: PresentationEntry = presented(
    "Archive Web Source",
    "Archive one web source while preserving its provenance evidence.",
);
