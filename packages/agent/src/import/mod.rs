//! Claude Code session import.
//!
//! Provides a pipeline that reads Claude Code JSONL session files and
//! imports them as fully-continuable Tron sessions.
//!
//! ## Pipeline
//!
//! ```text
//! parse → linearize → assemble → transform → write
//! ```
//!
//! ## Submodules
//!
//! | Module        | Purpose |
//! |---------------|---------|
//! | `types`       | Claude Code JSONL serde structs |
//! | `parser`      | File discovery + JSONL parsing |
//! | `tree`        | Tree linearization + turn derivation |
//! | `assembler`   | Chunk reassembly by `message.id` |
//! | `transformer` | Record → Tron event mapping |
//! | `cost`        | Cost estimation from tokens + model |
//! | `validator`   | Dry-run validation / warning surfacing (M28) |
//! | `writer`      | Transactional DB writer with dedup |
//! | `errors`      | `ImportError` enum |

pub mod assembler;
pub mod cost;
pub mod errors;
pub mod parser;
pub mod transformer;
pub mod tree;
pub mod types;
pub mod validator;
pub mod writer;

pub use errors::ImportError;
pub use parser::{discover_projects, discover_sessions, ClaudeProject, ClaudeSessionMeta};
pub use validator::{
    validate_session, ImportPreview, ImportValidation, ImportWarning, ImportWarningKind,
};
pub use writer::{import_session, ImportResult};
