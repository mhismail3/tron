//! Durable reusable-agent outbox import and assignment supervision.
//!
//! WorkerStore owns identities, FIFO assignment state, mixed topology, result
//! custody, and the transactional outbox. EventStore owns hidden transcript
//! sessions, semantic messages, delivery leases, and waits. These private
//! submodules are the only cross-store importer and never hold transactions in
//! both databases:
//!
//! - [`outbox_import`] reconciles provisioning and message admission effects.
//! - [`message_delivery`] materializes safe-boundary messages, waits, results,
//!   and client invalidations.
//! - [`assignment_driver`] supervises FIFO execution, recovery, structured
//!   joins, and terminalization.
//! - [`support`] owns deterministic envelope decoding and content-free events.
//!
//! Agent-runner workers use this same supervisor as single-assignment
//! `DirectWorker` agents. Recovery retains the stable agent, assignment, and
//! transcript; it never manufactures a replacement child.

mod assignment_driver;
mod message_delivery;
mod outbox_import;
mod support;
