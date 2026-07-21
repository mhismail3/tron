//! Direct trusted-local host primitives.
//!
//! These operations deliberately use the Tron user's ordinary host access.
//! Their constraints are reliability ceilings, not an application sandbox:
//! blocking filesystem work stays off the async executor, reads and traversal
//! are bounded, process trees have bounded I/O and deadlines, and mutations
//! publish through a same-directory atomic rename.
//!
//! ## Ownership
//!
//! - `read` owns bounded file reads and directory listing.
//! - `search` owns bounded literal traversal of UTF-8 files.
//! - `mutation` owns compare-and-swap edits and atomic writes.
//! - `process` owns exact-argv execution and bounded process-tree I/O.
//! - `web` owns bounded explicit-URL retrieval.
//! - `support` owns only shared admission, path resolution, and executor glue.

mod mutation;
mod process;
mod read;
mod search;
mod support;
mod web;

pub(super) use mutation::{filesystem_edit, filesystem_write};
pub(super) use process::process_run;
pub(super) use read::{filesystem_list, filesystem_read};
pub(super) use search::filesystem_search_text;
pub(super) use support::resolve_path;
pub(super) use web::web_fetch;
