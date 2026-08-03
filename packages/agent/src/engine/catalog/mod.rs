//! Engine catalog ownership: discovery and the live registry.
//!
//! `registry::LiveCatalog` owns current-process routing maps and the revision
//! cursor. The injected engine ledger stores only the durable monotonic catalog
//! revision plus invocation/idempotency records: registration persists the next
//! revision before changing live routing, and restart restores that scalar.
//! Function definitions are
//! self-sufficient; there is no parallel catalog-worker registry or namespace-
//! claim preflight. Registration requires an executable handler, so discovery
//! can never advertise a definition that the current process cannot route. The
//! live registry does not retain duplicate history or an append-only catalog
//! change plane.
//!
//! Discovery has one operation: return the functions visible to a concrete
//! actor. Relevance ranking and health selection belong to the worker-kernel
//! provider-surface resolver; the catalog has no generic search/filter DSL or
//! unused visibility-promotion workflow. Actor context is provenance plus
//! visibility scope, not an authorization token or permission object.

pub mod discovery;
pub mod registry;
