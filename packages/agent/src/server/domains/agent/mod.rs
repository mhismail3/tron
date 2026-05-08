//! agent domain worker.
//!
//! This module owns canonical function execution for the agent namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//!
//! ## Prompt Execution Flow
//!
//! 1. `/engine` builds an `EngineTransportRequest` for `agent::prompt`.
//! 2. The engine validates schema, authority, idempotency, approval, leases, and
//!    catalog revision before this domain handler runs.
//! 3. `agent::prompt` derives the run id, records the accepted prompt, enqueues
//!    hidden `agent::prompt_apply`, and returns the acknowledgement envelope.
//! 4. `agent::prompt_apply` acquires the session run guard and starts
//!    `agent::run_turn`.
//! 5. The turn runner resolves tools from the live engine catalog, writes session
//!    truth into the event store, invokes tool calls as child engine
//!    invocations, and publishes neutral engine stream events.
//! 6. Completion side effects, such as prompt-history capture and auto-retain,
//!    cross domains through hidden engine functions rather than private
//!    service calls.
//! 7. `/engine` subscriptions deliver those stream records to clients; the
//!    transport never owns agent behavior.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(crate) use worker::worker_module;

pub(crate) mod commands;
pub(crate) mod prompt_queue;
pub(crate) mod runtime;
pub(crate) mod stream;
pub(crate) mod worker;
