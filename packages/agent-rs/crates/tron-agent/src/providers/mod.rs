//! Real provider implementations for tool DI traits.
//!
//! These live in the binary crate because they depend on `tron-events` and
//! `tron-tasks`, which `tron-tools` intentionally doesn't depend on (it only
//! defines the traits).

pub mod apns_delegate;
pub mod sqlite_event_store;
pub mod sqlite_task_manager;

pub use apns_delegate::ApnsNotifyDelegate;
pub use sqlite_event_store::SqliteEventStoreQuery;
pub use sqlite_task_manager::SqliteTaskManagerDelegate;
