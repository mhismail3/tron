//! Primitive context assembly, compaction, and stateful prompt framing.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `context_manager` | Entry point — owns context lifecycle and compaction dependency projection |
//! | `compaction_engine` | Executes compaction: summarize older eligible messages, trim context |
//! | `summarizer` | Summarizer trait and recovery implementations |
//! | `message_store` | In-memory message buffer with compaction boundary tracking |
//! | `soul` | Static seed instruction for the primitive loop |
//! | `token_estimator` | Token counting and context budget calculations |
//! | `constants` | Token limits, compaction thresholds |
//! | `types` | Shared types for context subsystem |
//!
//! ## Entry Point
//!
//! [`context_manager::ContextManager`] — created per session, manages the full
//! context lifecycle from loading through compaction.
//!
//! ## Key Invariant
//!
//! The model-facing prompt begins with a concise behavioral seed and the
//! current direct-tool surface. The seed owns only durable behavioral intent;
//! live tool identity belongs to provider schemas, and exact authoring
//! mechanics belong to each tool contract. Durable worker state reaches the
//! model only through explicit worker results and inbox context; the context
//! manager does not maintain a parallel generic state-prompt channel.
//! Compaction uses token pressure to decide when to compact context, and only
//! commits when an older message window can be summarized and the result
//! reduces the durable context. Runtime compaction also requires the loop
//! handler to persist context-control proof before provider context is mutated;
//! proof failure restores the pre-compaction checkpoint instead of creating an
//! unaudited boundary.
//! The replaceable strategy seam is limited to the summarizer implementation:
//! compaction actions, epoch records, audit refs, and provider-safe projections
//! remain server-owned record-plane custody.

pub mod compaction_engine;
pub mod compaction_trigger;
pub mod constants;
pub mod context_manager;
pub mod message_store;
pub mod soul;
pub mod summarizer;
pub mod token_estimator;
pub mod types;
