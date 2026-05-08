//! Session operation implementations.
//!
//! The session worker owns lifecycle commands, reconstruction, exports,
//! archive/delete/resume behavior, and session stream records. Cross-domain
//! interactions such as worktree release must stay explicit in session deps or
//! public domain services.
