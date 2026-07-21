//! agent domain worker.
//!
//! This module owns the server-side prompt harness. Public agent functions are
//! limited to accepting prompts, reporting runtime status, and aborting active
//! work. Hidden functions serialize those prompts into the provider loop; the
//! model-facing tool surface after that loop starts is the direct typed
//! kernel tools plus the relevant engine-global worker tools.
//! Worker composition carries the optional model responder factory directly;
//! prompt validation reports `NotAvailable` when that runtime owner is absent.
//! Public and hidden agent payloads contain only values their handlers consume;
//! authenticated transport context owns workspace/session provenance instead
//! of duplicating ignored `workspaceId` or source labels in prompt commands.
//!
//! ## Prompt Execution Flow
//!
//! 1. `/engine` builds an `EngineTransportRequest` for `agent::prompt`.
//! 2. The authenticated transport validates schema, idempotency, visibility,
//!    and catalog revision before this domain handler runs. Transport auth
//!    authenticates the remote caller; local model tools carry runtime-owned
//!    causal provenance.
//! 3. `agent::prompt` derives the run id, records the accepted prompt, invokes
//!    hidden `agent::prompt_apply` synchronously through an engine-owned
//!    internal causal context, and returns an affirmative acknowledgement plus
//!    run id. Rejection is an engine error, never a negative success envelope.
//!    The prompt path does not race the background queue drainer for its own receipt.
//! 4. `agent::prompt_apply` acquires the session run guard and starts
//!    `agent::run_turn`.
//! 5. The turn runner builds provider input from session state and supplies
//!    direct typed kernel tools plus a compact relevant-worker projection.
//! 6. Provider tool calls are written as session truth and invoked as typed
//!    engine invocations with Agent identity. An agent-runner child also
//!    inherits its parent worker's causal depth, and the executor copies that
//!    depth onto nested direct tools so composition cannot reset loop limits.
//! 7. `/engine` subscriptions deliver prompt/runtime stream records to clients;
//!    transport code does not own agent behavior.
//! 8. The backend emits structured `component` + `agent_event` logs across
//!    runtime, loop, turn, provider stream, and tool-execution
//!    phases. Those logs carry durable IDs and lifecycle metadata for agent and
//!    operator inspection, while prompt text, streamed text, and tool arguments
//!    stay in the event/trace owners instead of logs.
//!
//! ## Submodules
//!
//! - `contract`: public and hidden `agent::*` tool contracts.
//! - `handlers` / `prompt`: worker entrypoints and prompt command flow.
//! - `loop`: turn execution, primitive tool invocation, and recovery.
//! - `context`: context assembly and compaction.
//! - `runtime` and `stream`: run lifecycle coordination and client stream
//!   projection.
//!
//! External integration tests construct a real server runtime through the
//! narrow re-exports below. The loop module itself remains private so tests do
//! not grow a dependency on its internal submodule layout. `SessionManager`
//! stays public for runtime construction; mutating session lifecycle operations
//! stay crate- or domain-owner scoped.

pub(crate) mod context;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod r#loop;
pub(crate) mod prompt;
pub(crate) use deps::Deps;
pub use r#loop::{Orchestrator, SessionManager};

pub(crate) mod runtime;
pub(crate) mod stream;

pub(crate) fn function_registrations(
    deps: &crate::domains::registration::composition::DomainRegistrationContext,
) -> crate::engine::Result<Vec<crate::domains::registration::composition::DomainFunctionRegistration>>
{
    let domain_deps = Deps::from_engine(deps);
    handlers::bind_functions(contract::function_definitions()?, domain_deps)
}
