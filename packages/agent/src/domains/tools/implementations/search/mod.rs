//! # tools/search — code search tools
//!
//! Two search strategies plus a unified front-end that picks the right
//! one based on the query shape.
//!
//! ## Submodules
//!
//! | Module          | Strategy  | Content |
//! |-----------------|-----------|---------|
//! | [`text_search`] | ripgrep   | Regex matching with file-glob filtering, context lines, and count/files/content output modes |
//! | [`ast_search`]  | ast-grep  | Structural pattern matching on parsed ASTs; language-aware (`js`, `py`, `rust`, etc.) |
//! | [`search_tool`] | unified   | The `Search` tool exposed to the agent — dispatches to text or AST based on `pattern` syntax |
//!
//! ## Invariants
//!
//! - The unified [`search_tool::SearchTool`] is the only implementation entry
//!   point behind the `tool::search` capability; [`text_search`] /
//!   [`ast_search`] are internal backends.
//! - Pattern syntax: ripgrep accepts regex, ast-grep accepts meta-variable
//!   templates. The front-end never rewrites the pattern — whichever
//!   backend was selected gets the pattern verbatim, so the agent always
//!   knows what engine it targeted.

pub mod ast_search;
pub mod search_tool;
pub mod text_search;
