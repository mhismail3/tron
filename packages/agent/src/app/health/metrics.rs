//! Prometheus metrics recorder and `/metrics` endpoint handler.

use metrics_exporter_prometheus::{PrometheusBuilder, PrometheusHandle};
use tracing::info;

/// Install the Prometheus metrics recorder (global).
///
/// Returns the `PrometheusHandle` used to render the `/metrics` endpoint.
/// Must be called once at server startup before any metrics are recorded.
pub fn install_recorder() -> PrometheusHandle {
    let builder = PrometheusBuilder::new();
    let handle = builder
        .install_recorder()
        .expect("failed to install metrics recorder");
    info!("prometheus metrics recorder installed");
    handle
}

/// Render Prometheus text format from the installed recorder.
pub fn render(handle: &PrometheusHandle) -> String {
    handle.render()
}

// Metric name constants to avoid typos across crates.

/// Engine client protocol requests total (counter, labels: message type).
pub const ENGINE_REQUESTS_TOTAL: &str = "engine_requests_total";
/// Engine client protocol errors total (counter, labels: message type, `error_type`).
pub const ENGINE_ERRORS_TOTAL: &str = "engine_errors_total";
/// Engine client protocol request duration seconds (histogram, labels: message type).
pub const ENGINE_REQUEST_DURATION_SECONDS: &str = "engine_request_duration_seconds";
/// Engine client WebSocket connections opened total (counter).
pub const ENGINE_WS_CONNECTIONS_TOTAL: &str = "engine_ws_connections_total";
/// Engine client WebSocket disconnections total (counter).
pub const ENGINE_WS_DISCONNECTIONS_TOTAL: &str = "engine_ws_disconnections_total";
/// Active engine client WebSocket connections (gauge).
pub const ENGINE_WS_CONNECTIONS_ACTIVE: &str = "engine_ws_connections_active";
/// Engine client stream delivery drops total (counter).
pub const ENGINE_WS_STREAM_DROPS_TOTAL: &str = "engine_ws_stream_drops_total";
/// Active agent runs (gauge).
pub const AGENT_RUNS_ACTIVE: &str = "agent_runs_active";
/// Agent turns total (counter, labels: model).
pub const AGENT_TURNS_TOTAL: &str = "agent_turns_total";
/// Agent turn duration seconds (histogram, labels: model).
pub const AGENT_TURN_DURATION_SECONDS: &str = "agent_turn_duration_seconds";
/// Provider requests total (counter, labels: provider).
pub const PROVIDER_REQUESTS_TOTAL: &str = "provider_requests_total";
/// Provider errors total (counter, labels: provider, status).
pub const PROVIDER_ERRORS_TOTAL: &str = "provider_errors_total";
/// Provider retries total (counter, labels: category).
pub const PROVIDER_RETRIES_TOTAL: &str = "provider_retries_total";
/// Provider request duration seconds (histogram, labels: provider).
pub const PROVIDER_REQUEST_DURATION_SECONDS: &str = "provider_request_duration_seconds";
/// Provider time-to-first-token seconds (histogram, labels: provider).
pub const PROVIDER_TTFT_SECONDS: &str = "provider_ttft_seconds";
/// Provider degraded state (gauge, labels: provider). 1 = degraded, 0 = healthy.
pub const PROVIDER_DEGRADED: &str = "provider_degraded";
/// Capability invocations total (counter, labels: capability).
pub const CAPABILITY_INVOCATIONS_TOTAL: &str = "capability_invocations_total";
/// Capability invocation duration seconds (histogram, labels: capability).
pub const CAPABILITY_INVOCATION_DURATION_SECONDS: &str = "capability_invocation_duration_seconds";
/// LLM tokens total (counter, labels: provider, direction).
pub const LLM_TOKENS_TOTAL: &str = "llm_tokens_total";
/// Active sessions (gauge).
pub const SESSIONS_ACTIVE: &str = "sessions_active";
/// Compaction total (counter, labels: status).
pub const COMPACTION_TOTAL: &str = "compaction_total";
/// Compaction duration seconds (histogram).
pub const COMPACTION_DURATION_SECONDS: &str = "compaction_duration_seconds";
/// Active browser sessions (gauge).
pub const BROWSER_SESSIONS_ACTIVE: &str = "browser_sessions_active";
/// Auth token refresh total (counter, labels: provider, status).
pub const AUTH_REFRESH_TOTAL: &str = "auth_refresh_total";
/// WebSocket connection duration seconds (histogram).
pub const WS_CONNECTION_DURATION_SECONDS: &str = "ws_connection_duration_seconds";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_and_render() {
        // Build a recorder + handle (no global install to avoid test conflicts).
        let handle = PrometheusBuilder::new().build_recorder().handle();

        // Should produce valid (possibly empty) Prometheus text.
        let output = handle.render();
        // Empty or contains valid text — no panic.
        assert!(output.is_empty() || output.contains('#') || output.contains('\n'));
    }

    #[test]
    fn metric_constants_are_snake_case() {
        let names = [
            ENGINE_REQUESTS_TOTAL,
            ENGINE_ERRORS_TOTAL,
            ENGINE_REQUEST_DURATION_SECONDS,
            ENGINE_WS_CONNECTIONS_TOTAL,
            ENGINE_WS_DISCONNECTIONS_TOTAL,
            ENGINE_WS_CONNECTIONS_ACTIVE,
            ENGINE_WS_STREAM_DROPS_TOTAL,
            AGENT_RUNS_ACTIVE,
            AGENT_TURNS_TOTAL,
            AGENT_TURN_DURATION_SECONDS,
            PROVIDER_REQUESTS_TOTAL,
            PROVIDER_ERRORS_TOTAL,
            PROVIDER_RETRIES_TOTAL,
            PROVIDER_REQUEST_DURATION_SECONDS,
            PROVIDER_TTFT_SECONDS,
            PROVIDER_DEGRADED,
            CAPABILITY_INVOCATIONS_TOTAL,
            CAPABILITY_INVOCATION_DURATION_SECONDS,
            LLM_TOKENS_TOTAL,
            SESSIONS_ACTIVE,
            COMPACTION_TOTAL,
            COMPACTION_DURATION_SECONDS,
            BROWSER_SESSIONS_ACTIVE,
            AUTH_REFRESH_TOTAL,
            WS_CONNECTION_DURATION_SECONDS,
        ];
        for name in names {
            assert!(
                name.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "metric name '{name}' must be snake_case"
            );
        }
    }
}
