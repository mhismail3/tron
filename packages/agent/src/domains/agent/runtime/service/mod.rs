//! Prompt run orchestration services.
//!
//! `execute` owns the linear run-turn lifecycle, while sibling modules own the
//! request DTO, dependency bundle, run plan, spawning, stream event publication,
//! lightweight session title generation, and the major run-turn phases. The
//! service also owns the outer structured logging lifecycle for accepted prompt
//! runs so logs, session events, and trace records share common
//! run/session/trace identifiers. `PromptRequest` is the single
//! plan-level owner of accepted invocation causality; execution moves that value
//! into its turn and completion path. Completion emits the runtime-owned
//! durable session-update projection after the turn's synchronous persistence
//! calls have committed; it does not rebuild that wire event, retain
//! session-cache ownership, or duplicate final assistant state.
//! Before durable history is reconstructed, prompt admission atomically closes
//! any terminal prior turn's unmatched capability starts and broadcasts those
//! row-backed repairs to live clients. A repair failure rejects the prompt
//! before `message.user` persistence or provider construction. Durable
//! prior-history reconstruction and the new `message.user` append are likewise
//! prerequisites for model execution; either persistence failure releases the
//! run without opening a provider stream. Normal completion and every admitted
//! setup failure publish agent-end, canonical failure when present,
//! processing-false, and ready while the matching run still serializes
//! same-session admission; the run slot and its projection are released before
//! that boundary unlocks. Prompt-run composition derives broadcast access from
//! its authoritative orchestrator and owns its event persister; the session
//! cache retains only reconstructed event-store state and no parallel runtime
//! service. Completion does not maintain a second final-answer state. Run-turn
//! admission snapshots settings from the authoritative `SettingsRuntime`; the
//! spawned run keeps that immutable value instead of consulting a second
//! mutable settings owner. Main
//! response and background title providers are both created from that same
//! admitted API-settings snapshot. Each resumed prompt fail-closed reads the
//! durable sequence and turn high-water marks, then seeds its agent from the
//! maximum of reconstructed, completed, and started turns. A cancelled
//! zero-content attempt therefore consumes its ordinal, while corrupt or
//! exhausted counters never wrap or reuse identity.

use crate::domains::agent::r#loop::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::domains::agent::r#loop::orchestrator::agent_runner::run_agent;
use crate::domains::agent::r#loop::orchestrator::core::StartedRun;
use crate::domains::agent::r#loop::types::{AgentConfig, RunContext};

use super::cleanup::{PromptRunCleanup, ShutdownCancelForwarder};
use crate::domains::agent::runtime::runtime::{
    build_user_content_override, build_user_event_payload, load_session_update_event,
    persist_user_message_event, resume_prompt_session,
};
use crate::engine::{CausalContext, FunctionId, InvocationId};

mod agent_build;
mod completion;
mod deps;
mod events;
mod execute;
mod plan;
mod request;
mod spawn;
mod title_generation;

pub use deps::{PromptEngineCausality, PromptRuntimeDeps};
pub(super) use events::publish_prompt_runtime_stream;
pub(super) use execute::execute_prompt_run;
pub(super) use plan::PromptRunPlan;
pub use request::PromptRequest;
pub use spawn::spawn_prompt_run;
use title_generation::{SessionTitleGenerationRequest, spawn_session_title_generation};
