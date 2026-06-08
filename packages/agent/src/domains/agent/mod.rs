//! agent domain worker.
//!
//! This module owns the server-side prompt harness. Public agent functions are
//! limited to accepting prompts, reporting runtime status, and aborting active
//! work. Hidden functions serialize those prompts into the provider loop; the
//! model-facing capability surface after that loop starts is the single
//! `capability::execute` primitive.
//!
//! ## Prompt Execution Flow
//!
//! 1. `/engine` builds an `EngineTransportRequest` for `agent::prompt`.
//! 2. The engine validates schema, authority, idempotency, leases, and
//!    catalog revision before this domain handler runs.
//! 3. `agent::prompt` derives the run id, records the accepted prompt, invokes
//!    hidden `agent::prompt_apply` synchronously through the engine fabric, and
//!    returns the acknowledgement envelope. The prompt path does not race the
//!    background queue drainer for its own receipt.
//! 4. `agent::prompt_apply` acquires the session run guard and starts
//!    `agent::run_turn`.
//! 5. The turn runner builds provider input from session state and supplies one
//!    model-facing tool named `execute`.
//! 6. Provider tool calls are written as session truth and invoked as child
//!    `capability::execute` engine invocations.
//! 7. `/engine` subscriptions deliver prompt/runtime stream records to clients;
//!    transport code does not own agent behavior.
//!
//! ## Submodules
//!
//! - `contract`: public and hidden `agent::*` capability contracts.
//! - `handlers` / `prompt`: worker entrypoints and prompt command flow.
//! - `loop`: turn execution, primitive tool invocation, and recovery.
//! - `context`: context assembly and compaction.
//! - `runtime` and `stream`: run lifecycle coordination and client stream
//!   projection.
//!
//! External integration tests construct a real server runtime through the
//! narrow re-exports below. The loop module itself remains private so tests do
//! not grow a dependency on its internal submodule layout.

pub(crate) mod context;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod r#loop;
pub(crate) mod prompt;
pub(crate) use deps::Deps;
pub use r#loop::{Orchestrator, ProfileRuntime, SessionManager};
pub(crate) use worker::worker_module;

pub(crate) mod runtime;
pub(crate) mod stream;
pub(crate) mod worker;
