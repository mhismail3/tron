//! Tool registry factory — creates a populated `ToolRegistry` with all built-in tools.
//!
//! Separated from `main.rs` to keep the binary entry point focused on
//! initialization orchestration and server lifecycle.

use std::sync::Arc;

use tron::events::EventStore;
use tron::tools::registry::ToolRegistry;

use crate::PushServiceOption;

/// Configuration for tool registry creation.
///
/// Captures shared resources (event store, API keys) so the
/// tool factory closure can create real provider implementations.
pub(crate) struct ToolRegistryConfig {
    pub event_store: Arc<EventStore>,
    pub brave_api_key: Option<String>,
    #[cfg_attr(not(feature = "apns"), allow(dead_code))]
    pub push_service: PushServiceOption,
    /// Shared HTTP client (connection pool reused across tools).
    pub http_client: reqwest::Client,
    /// Sandbox settings for the Bash tool.
    pub sandbox_settings: tron::settings::BashSandboxSettings,
    /// Computer use settings.
    pub computer_use_settings: tron::settings::ComputerUseSettings,
    /// Broadcast sender for Display tool streaming (DisplayFrame events).
    pub display_event_tx: Option<tokio::sync::broadcast::Sender<tron::core::events::TronEvent>>,
    /// `McpSearch` meta-tool (searches all MCP server tools by keyword).
    pub mcp_search: Option<Arc<dyn tron::tools::traits::TronTool>>,
    /// `McpCall` meta-tool (calls a tool on an MCP server).
    pub mcp_call: Option<Arc<dyn tron::tools::traits::TronTool>>,
}

/// Create a populated tool registry with built-in tools.
///
/// Called once per agent run to create a fresh registry. Registration matches
/// the TypeScript server:
/// - Tools with real backends use real providers
/// - `NotifyApp`: conditionally registered (only with APNS backend)
/// - Subagent tools: NOT registered (stubs return "not available", confusing LLM)
pub(crate) fn create_tool_registry(config: &ToolRegistryConfig) -> ToolRegistry {
    use tron::tools::backends::{
        RealFileSystem, ReqwestHttpClient, StubNotifyDelegate, TokioProcessRunner,
    };

    let fs: Arc<dyn tron::tools::traits::FileSystemOps> = Arc::new(RealFileSystem);
    let runner: Arc<dyn tron::tools::traits::ProcessRunner> = Arc::new(TokioProcessRunner);
    let http: Arc<dyn tron::tools::traits::HttpClient> =
        Arc::new(ReqwestHttpClient::from_client(config.http_client.clone()));

    let mut registry = ToolRegistry::new();

    // 1–3: Filesystem tools
    registry.register(Arc::new(tron::tools::fs::read::ReadTool::new(fs.clone())));
    registry.register(Arc::new(tron::tools::fs::write::WriteTool::new(fs.clone())));
    registry.register(Arc::new(tron::tools::fs::edit::EditTool::new(fs.clone())));

    // 4: Bash (with blob store for large output storage + sandbox settings)
    let blob_store: Arc<dyn tron::tools::traits::BlobStore> = config.event_store.clone();
    registry.register(Arc::new(
        tron::tools::system::bash::BashTool::new(runner.clone(), Some(blob_store))
            .with_sandbox_settings(
                config.sandbox_settings.default_image.clone(),
                config.sandbox_settings.network_enabled,
            ),
    ));

    // 5: Search
    let cu_runner = runner.clone();
    registry.register(Arc::new(tron::tools::search::search_tool::SearchTool::new(
        runner,
    )));

    // 6: Find
    registry.register(Arc::new(tron::tools::fs::find::FindTool::new()));

    // 7: AskUserQuestion
    registry.register(Arc::new(
        tron::tools::ui::ask_user::AskUserQuestionTool::new(),
    ));

    // 8: GetConfirmation
    registry.register(Arc::new(
        tron::tools::ui::get_confirmation::GetConfirmationTool::new(),
    ));

    // 9: NotifyApp — relay or stub fallback
    let notify_delegate: Arc<dyn tron::tools::traits::NotifyDelegate> = {
        #[cfg(feature = "apns")]
        match config.push_service {
            Some(crate::PushService::Relay(ref relay)) => Arc::new(
                tron::server::platform::apns::relay_delegate::RelayNotifyDelegate::new(
                    relay.clone(),
                    config.event_store.clone(),
                ),
            ),
            None => Arc::new(StubNotifyDelegate),
        }
        #[cfg(not(feature = "apns"))]
        {
            Arc::new(StubNotifyDelegate)
        }
    };
    registry.register(Arc::new(tron::tools::ui::notify::NotifyAppTool::new(
        notify_delegate,
    )));

    // 10: WebFetch (always available)
    registry.register(Arc::new(tron::tools::web::web_fetch::WebFetchTool::new(
        http.clone(),
    )));

    // 11: WebSearch — conditional on Brave API key
    if let Some(ref api_key) = config.brave_api_key {
        registry.register(Arc::new(tron::tools::web::web_search::WebSearchTool::new(
            http,
            api_key.clone(),
        )));
    }

    // 12: Display (rich content presentation — images, streams)
    //     Uses blob storage for images to avoid exceeding WebSocket message limits.
    //     event_tx is for streaming DisplayFrame events to connected iOS clients.
    let display_blob_store: Arc<dyn tron::tools::traits::BlobStore> = config.event_store.clone();
    let mut display_tool = tron::tools::ui::display::DisplayTool::new(Some(display_blob_store));
    if let Some(ref tx) = config.display_event_tx {
        display_tool = display_tool.with_event_tx(tx.clone());
    }
    registry.register(Arc::new(display_tool));

    // 13: ComputerUse (screenshot, click, type, keypress, scroll, window management)
    registry.register(Arc::new(
        tron::tools::ui::computer_use::ComputerUseTool::new(
            cu_runner,
            config.computer_use_settings.confirm_before_action,
            config.computer_use_settings.screenshot_throttle_ms,
        ),
    ));

    // Subagent tools: registered separately via SubagentManager (see main)

    // ManageJob + Wait — registered in the tool factory closure where
    // both ProcessManager and SubagentManager are available for JobManager creation.
    // See the `tool_factory` closure in main().

    // MCP meta-tools (McpSearch + McpCall replace individual tool registration)
    if let Some(ref tool) = config.mcp_search {
        registry.register(tool.clone());
    }
    if let Some(ref tool) = config.mcp_call {
        registry.register(tool.clone());
    }

    tracing::debug!(tool_count = registry.len(), tools = ?registry.names(), "tool registry created");
    registry
}
