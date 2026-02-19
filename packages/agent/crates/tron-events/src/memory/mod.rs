//! Memory manager and ledger writer for the Tron agent.

pub mod errors;
pub mod manager;
pub mod trigger;
pub mod types;

pub use errors::MemoryError;
pub use manager::{MemoryManager, MemoryManagerDeps};
pub use trigger::CompactionTrigger;
pub use types::{
    CompactionTriggerConfig, CompactionTriggerInput, CompactionTriggerResult, CycleInfo,
    LedgerWriteOpts, LedgerWriteResult,
};
