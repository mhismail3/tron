//! Task, project, and area CRUD with SQLite persistence.

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
