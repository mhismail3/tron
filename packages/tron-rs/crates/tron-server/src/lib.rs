pub mod client;
pub mod compat;
pub mod event_bridge;
pub mod handlers;
pub mod orchestrator;
pub mod rpc;
pub mod server;

pub use orchestrator::{AgentOrchestrator, AgentState, EngineOrchestrator, PromptParams, PromptResult};
pub use server::{ServerConfig, ServerHandle, start, start_with_telemetry};
