use super::support::*;

#[test]
fn transport_agent_observability_roots_are_split_and_explicit() {
    for (path, limit) in [
        ("packages/agent/src/transport/engine/socket/mod.rs", 750),
        (
            "packages/agent/src/domains/agent/loop/turn_runner/persistence.rs",
            750,
        ),
        ("packages/agent/src/shared/observability/transport.rs", 750),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-6 file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/agent/src/transport/engine/socket/subscriptions.rs",
        "packages/agent/src/domains/agent/loop/turn_runner/persistence/tests.rs",
        "packages/agent/src/shared/observability/transport/tests.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-6 expected split owner missing: {path}"
        );
    }

    let socket = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");
    assert!(
        !socket.contains("async fn push_subscription_events(")
            && !socket.contains("async fn handle_subscribe(")
            && !socket.contains("async fn handle_poll(")
            && !socket.contains("async fn handle_ack("),
        "socket root must not own subscription polling, cursor advancement, or ack handling"
    );

    for path in [
        "packages/agent/src/domains/agent/loop/turn_runner/persistence.rs",
        "packages/agent/src/shared/observability/transport.rs",
    ] {
        let contents = read_repo_file(path);
        assert!(
            !contents.contains("#[cfg(test)]\nmod tests {"),
            "{path} must keep tests in its child test module"
        );
    }
}
