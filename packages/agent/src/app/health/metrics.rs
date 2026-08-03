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

#[cfg(test)]
mod tests {
    use super::PrometheusBuilder;

    #[test]
    fn install_and_render() {
        // Build a recorder + handle (no global install to avoid test conflicts).
        let handle = PrometheusBuilder::new().build_recorder().handle();

        // Should produce valid (possibly empty) Prometheus text.
        let output = handle.render();
        // Empty or contains valid text — no panic.
        assert!(output.is_empty() || output.contains('#') || output.contains('\n'));
    }
}
