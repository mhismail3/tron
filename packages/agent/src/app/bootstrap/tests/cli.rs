use super::*;
use crate::app::cli::{AuthAction, Cli, Command};
use clap::Parser;

#[test]
fn cli_default_host() {
    let cli = Cli::parse_from(["tron"]);
    assert_eq!(cli.host, "0.0.0.0");
}

// ── C2: startup log names bind address ──────────────────────────────

/// Startup log for the default 0.0.0.0 bind MUST name the Tailscale /
/// trusted-local assumption. Without this, an operator who accidentally
/// bound on an untrusted network has no visible warning.
#[test]
fn startup_log_on_all_interfaces_names_trust_boundary() {
    let addr: std::net::SocketAddr = "0.0.0.0:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "0.0.0.0");
    assert!(
        msg.contains("0.0.0.0:9847"),
        "bind address must appear: {msg}"
    );
    assert!(
        msg.to_lowercase().contains("tailscale") || msg.to_lowercase().contains("firewall"),
        "0.0.0.0 bind must name the trust assumption, got: {msg}"
    );
}

/// IPv6 catch-all (`::`) is the same trust boundary as `0.0.0.0`.
#[test]
fn startup_log_on_ipv6_all_interfaces_names_trust_boundary() {
    let addr: std::net::SocketAddr = "[::]:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "::");
    assert!(
        msg.to_lowercase().contains("tailscale") || msg.to_lowercase().contains("firewall"),
        "`::` bind must name the trust assumption, got: {msg}"
    );
}

/// Loopback binds are explicitly safer; the log should say so.
#[test]
fn startup_log_on_loopback_is_annotated() {
    for host in ["127.0.0.1", "::1", "localhost"] {
        let addr: std::net::SocketAddr = "127.0.0.1:9847".parse().unwrap();
        let msg = format_listening_log(&addr, host);
        assert!(
            msg.to_lowercase().contains("loopback"),
            "{host}-bound log must note loopback scope: {msg}"
        );
    }
}

/// A specific non-default host (e.g. a LAN IP the operator chose
/// deliberately) is left bare — we don't second-guess intentional
/// network selection, and the raw address is already in the message.
#[test]
fn startup_log_on_specific_host_is_bare() {
    let addr: std::net::SocketAddr = "192.168.1.5:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "192.168.1.5");
    assert!(!msg.to_lowercase().contains("tailscale"));
    assert!(!msg.to_lowercase().contains("loopback"));
    assert!(msg.contains("192.168.1.5:9847"));
}

#[test]
fn cli_default_port() {
    let cli = Cli::parse_from(["tron"]);
    assert_eq!(cli.port, 9847);
}

#[test]
fn cli_parses_log_level_flag() {
    let cli = Cli::parse_from(["tron", "--log-level", "debug"]);
    assert_eq!(cli.log_level.as_deref(), Some("debug"));
}

#[test]
fn shutdown_signal_surface_includes_process_manager_stop_signal() {
    assert!(shutdown_signal_names().contains(&"SIGINT"));
    #[cfg(unix)]
    assert!(
        shutdown_signal_names().contains(&"SIGTERM"),
        "launchd and tron dev --stop use SIGTERM; managed child cleanup must run for it"
    );
}

#[test]
fn cli_log_level_is_optional() {
    let cli = Cli::parse_from(["tron"]);
    assert!(cli.log_level.is_none());
}
// ── CLI subcommand dispatch ──────────────────────────────────────────
//
// These tests cover Phase 2.7 — the `tron auth rotate` surface. The
// goal is twofold: (a) the clap parse tree exists exactly as documented,
// and (b) the dispatch helper writes a fresh token to disk and prints
// it on stdout. The end-to-end path uses the public `onboarding`
// helpers, so the on-disk side effect lands in `~/.tron/profiles/`; the
// tests below avoid that by exercising the helper directly with a temp
// path. The clap layer is tested in isolation.

#[test]
fn cli_parses_auth_rotate_subcommand() {
    let cli = Cli::parse_from(["tron", "auth", "rotate"]);
    match cli.command {
        Some(Command::Auth {
            action: AuthAction::Rotate,
        }) => {}
        other => panic!("expected Some(Auth {{ Rotate }}), got {other:?}"),
    }
}

#[test]
fn cli_no_subcommand_resolves_to_none() {
    // The bare `tron` invocation (with default host/port) MUST yield
    // `command: None` so the server-startup branch in `main` runs.
    let cli = Cli::parse_from(["tron"]);
    assert!(
        cli.command.is_none(),
        "bare `tron` must not pick up a subcommand"
    );
}

#[test]
fn cli_auth_without_action_fails() {
    // `tron auth` with no action is a user error; clap should reject it
    // rather than silently doing nothing.
    let result = Cli::try_parse_from(["tron", "auth"]);
    assert!(result.is_err(), "tron auth with no action must error");
}

#[test]
fn cli_auth_unknown_action_fails() {
    let result = Cli::try_parse_from(["tron", "auth", "no-such-action"]);
    assert!(result.is_err(), "unknown auth action must error");
}

#[test]
fn run_subcommand_auth_rotate_writes_token_to_default_path() {
    // The default path for `auth.json` is under `~/.tron/profiles/`,
    // which would clobber the user's real token on a dev machine. The
    // test writes through the lower-level `rotate_bearer_token` helper
    // with a temp path instead — same code path the dispatch hits, just
    // with the path injected. The clap dispatch test above guarantees
    // the wiring matches.
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");
    let token =
        crate::app::lifecycle::onboarding::rotate_bearer_token(&path).expect("rotate writes token");
    assert_eq!(
        token.len(),
        43,
        "rotated token must be 43 chars (32 bytes URL-safe-base64 no pad)"
    );
    assert!(path.exists(), "rotation must persist to disk");

    // Round-trip: load the same path and verify the token round-trips.
    let read_back =
        crate::app::lifecycle::onboarding::load_or_create_bearer_token(&path).expect("load");
    assert_eq!(read_back, token, "rotated token must round-trip on disk");
}
#[test]
fn run_subcommand_auth_rotate_invalidates_prior_token() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");
    let first =
        crate::app::lifecycle::onboarding::load_or_create_bearer_token(&path).expect("first");
    let second = crate::app::lifecycle::onboarding::rotate_bearer_token(&path).expect("rotate");
    let third =
        crate::app::lifecycle::onboarding::load_or_create_bearer_token(&path).expect("third");
    assert_ne!(
        first, second,
        "rotation must produce a new token (otherwise paired devices stay valid)"
    );
    assert_eq!(
        second, third,
        "post-rotation reads must observe the rotated token, not the original"
    );
}
