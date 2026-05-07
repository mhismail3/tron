//! # tools/fs — filesystem tools
//!
//! Tool implementations that read, write, and mutate files on the local
//! filesystem. All four tools share a common contract: paths are passed
//! through `tools::utils::path` canonicalisation and every call flows
//! through the injected `ProcessRunner` / `FileSystemOps` traits
//! ([`crate::tools::traits`]), so tests swap a stub backend without
//! touching real disk.
//!
//! ## Submodules
//!
//! | Module | Tool   | Content |
//! |--------|--------|---------|
//! | [`read`]      | `Read`  | Read a file with optional line-range, offset, and limit; decodes images and PDFs |
//! | [`mod@write`] | `Write` | Overwrite a file atomically; refuses to create files not previously read |
//! | [`edit`]      | `Edit`  | Exact-string search-and-replace; preserves indentation; unique-match required |
//! | [`find`]      | `Find`  | Glob pattern matching with `.gitignore` honoring |
//!
//! ## Invariants
//!
//! - `write::WriteTool` refuses to overwrite a file the current session has
//!   not read — guards against the LLM silently clobbering unfamiliar content.
//! - [`edit::EditTool`] rejects non-unique `old_string` matches rather than
//!   picking the first — removes ambiguity that would make the edit silently
//!   target the wrong location.
//! - Every handler canonicalises via `tools::utils::path::normalise` before
//!   reaching the backend, so `../` traversal outside the working directory
//!   is documented by the trusted-local INVARIANT on
//!   [`crate::server::services::filesystem_service`] and NOT re-checked here.

pub mod edit;
pub mod find;
pub mod read;
pub mod write;
