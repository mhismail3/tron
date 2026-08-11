//! Direct trusted-local host primitives.
//!
//! These operations deliberately use the Tron user's ordinary host access.
//! Their constraints are reliability ceilings, not an application sandbox:
//! blocking filesystem work stays off the async executor, reads and traversal
//! are bounded, process trees have bounded I/O and deadlines, and mutations
//! publish through a same-directory atomic rename. Raw web retrieval defaults
//! to a context-safe 128 KiB/30-second budget and hashes retained content;
//! semantic extraction and crawling remain worker-owned behavior.
//! Source-owned workspace effects drive shared-checkout collision control.
//! Reusable assignments may mutate only canonical workspace-relative prefixes
//! in their immutable write-scope snapshot. Exact claims allow disjoint writers
//! to proceed concurrently while overlapping paths queue FIFO. A workspace
//! `process_run` holds the whole-workspace lease until its captured process
//! group exits or is cancelled. A private pre-exec gate prevents user code from
//! running until PID and process-birth identity are durable, closing the
//! spawn/bind crash boundary. Root sessions use their durable session identity
//! rather than a synthetic assignment or authority grant. Startup closes any
//! unbound gates, cancels orphaned claims, and signals only a process group
//! whose OS-reported birth identity still matches its durable spawn record,
//! preventing PID-reuse matches.
//! None of this contains the process or reduces its normal local-user authority.
//!
//! ## Ownership
//!
//! - `read` owns bounded file reads and directory listing.
//! - `search` owns bounded literal traversal of UTF-8 files.
//! - `mutation` owns compare-and-swap edits and atomic writes.
//! - `claims` owns source-contract workspace effects, canonical scoped-write
//!   admission, durable fair reservations, and restart-safe process custody.
//! - `process` owns exact-argv execution and bounded process-tree I/O.
//!   Structured stdin values are serialized exactly once; strings remain exact
//!   bytes so callers never need a second JSON encoding layer.
//! - `web` owns bounded explicit-URL retrieval.
//! - `support` owns only shared admission, path resolution, and executor glue.

mod claims;
mod mutation;
mod process;
mod read;
mod search;
mod support;
mod web;

pub(crate) use mutation::{filesystem_edit, filesystem_write};
pub(crate) use process::process_run;
pub(crate) use read::{filesystem_list, filesystem_read};
pub(super) use search::filesystem_search_text;
pub(crate) use support::resolve_path;
pub(super) use web::web_fetch;
