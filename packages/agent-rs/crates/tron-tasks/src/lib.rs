//! # tron-tasks
//!
//! Task, project, and area CRUD with `SQLite` persistence.
//!
//! Implements the full task management system with:
//!
//! - **Three-tier architecture**: Repository (SQL), Service (business logic),
//!   Context builder (LLM injection).
//! - **PARA model**: Areas → Projects → Tasks (2-level hierarchy for tasks).
//! - **Dependency tracking**: `Blocks` and `Related` relationships with
//!   circular dependency detection (BFS).
//! - **Activity audit trail**: Every mutation is logged with old/new values.
//! - **FTS5 search**: Full-text search on tasks and areas.
//! - **Auto-transitions**: `started_at`, `completed_at` managed automatically
//!   based on status changes.
//!
//! ## Usage
//!
//! ```rust,no_run
//! use tron_tasks::{migrations, TaskService, TaskCreateParams};
//! use rusqlite::Connection;
//!
//! let conn = Connection::open_in_memory().unwrap();
//! migrations::run_migrations(&conn).unwrap();
//!
//! let task = TaskService::create_task(&conn, &TaskCreateParams {
//!     title: "Fix authentication bug".to_string(),
//!     ..Default::default()
//! }).unwrap();
//! ```

#![deny(unsafe_code)]

pub mod context;
pub mod errors;
pub mod migrations;
pub mod repository;
pub mod service;
pub mod types;

pub use context::build_task_context;
pub use errors::TaskError;
pub use repository::TaskRepository;
pub use service::TaskService;
pub use types::*;
