//! Static gates for live evidence harness behavior.

use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

#[test]
fn live_harness_sessions_stay_out_of_user_dashboard_by_default() {
    let fixtures = repo_root().join("packages/agent/tests/fixtures");
    let shared = std::fs::read_to_string(fixtures.join("rwo_n16_live_agent_harness.py"))
        .expect("read shared live harness");
    for required in [
        "def start_isolated_server",
        "def maybe_start_isolated_server",
        "\"--use-current-server\"",
        "they do not appear in the user's dashboard",
        "TRON_HARNESS_DB_PATH",
        "TRON_ENGINE_WORKER_ENDPOINT",
        "default harness path does not deep-link newly-created sessions",
    ] {
        assert!(
            shared.contains(required),
            "shared live harness must keep isolated default marker `{required}`"
        );
    }

    for rel in [
        "roc2_hosted_model_matrix.py",
        "roc3_local_model_breadth.py",
        "roc5_resource_truth_matrix.py",
        "roc7_long_running_compaction.py",
        "rwo_n15_live_agent_harness.py",
        "rwo_n16_live_agent_harness.py",
        "rwo_n16b_live_agent_harness.py",
        "rwo_n17_live_multi_session_harness.py",
    ] {
        let content = std::fs::read_to_string(fixtures.join(rel))
            .unwrap_or_else(|error| panic!("failed to read {rel}: {error}"));
        assert!(
            content.contains("maybe_start_isolated_server")
                && content.contains("serverMode")
                && content.contains("add_runtime_args"),
            "{rel} must create live evidence sessions in an isolated server unless --use-current-server is explicit"
        );
    }

    let terminal_guard = std::fs::read_to_string(fixtures.join("session_terminal_guard.py"))
        .expect("read terminal guard");
    assert!(
        terminal_guard.contains("TRON_HARNESS_DB_PATH"),
        "terminal guard must inspect the isolated harness DB, not the user's dashboard DB"
    );
}
