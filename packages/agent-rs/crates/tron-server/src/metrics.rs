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

/// RPC requests total (counter, labels: method).
pub const RPC_REQUESTS_TOTAL: &str = "rpc_requests_total";
/// RPC errors total (counter, labels: method, error_type).
pub const RPC_ERRORS_TOTAL: &str = "rpc_errors_total";
/// RPC request duration seconds (histogram, labels: method).
pub const RPC_REQUEST_DURATION_SECONDS: &str = "rpc_request_duration_seconds";
/// WebSocket connections opened total (counter).
pub const WS_CONNECTIONS_TOTAL: &str = "ws_connections_total";
/// WebSocket disconnections total (counter).
pub const WS_DISCONNECTIONS_TOTAL: &str = "ws_disconnections_total";
/// Active WebSocket connections (gauge).
pub const WS_CONNECTIONS_ACTIVE: &str = "ws_connections_active";
/// Broadcast drops total (counter).
pub const WS_BROADCAST_DROPS_TOTAL: &str = "ws_broadcast_drops_total";
/// Active agent runs (gauge).
pub const AGENT_RUNS_ACTIVE: &str = "agent_runs_active";
/// Agent turns total (counter, labels: model).
pub const AGENT_TURNS_TOTAL: &str = "agent_turns_total";
/// Agent turn duration seconds (histogram).
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
            RPC_REQUESTS_TOTAL,
            RPC_ERRORS_TOTAL,
            RPC_REQUEST_DURATION_SECONDS,
            WS_CONNECTIONS_TOTAL,
            WS_DISCONNECTIONS_TOTAL,
            WS_CONNECTIONS_ACTIVE,
            WS_BROADCAST_DROPS_TOTAL,
            AGENT_RUNS_ACTIVE,
            AGENT_TURNS_TOTAL,
            AGENT_TURN_DURATION_SECONDS,
            PROVIDER_REQUESTS_TOTAL,
            PROVIDER_ERRORS_TOTAL,
            PROVIDER_RETRIES_TOTAL,
            PROVIDER_REQUEST_DURATION_SECONDS,
            PROVIDER_TTFT_SECONDS,
            PROVIDER_DEGRADED,
        ];
        for name in names {
            assert!(
                name.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "metric name '{name}' must be snake_case"
            );
        }
    }
}
