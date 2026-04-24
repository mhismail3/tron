//! System handlers: ping, getInfo, shutdown, getDiagnostics, auto-updater.
//!
//! The three updater handlers below (`system.checkForUpdates`,
//! `system.getUpdateStatus`, `system.applyUpdate`) are the RPC surface for
//! the user-mode auto-updater (Plan §H.2, Phase 5.5). They never mutate the
//! binary themselves — the install pipeline (codesign-verify → atomic swap
//! → ping → rollback) lands in Phase 6 alongside the DMG release workflow.
//! `ApplyUpdateHandler` is wired today as a `{ status: "noop" }` stub so
//! the iOS "Install now" button can be laid out and tested against a real
//! response shape; flipping it to `status: "installing"` is a pure
//! server-side change once the pipeline exists.

use std::collections::BTreeMap;

use async_trait::async_trait;
use serde_json::Value;
use tracing::{instrument, warn};

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{CLIENT_VERSION_UNSUPPORTED, RpcError};
use crate::server::rpc::registry::{MethodHandler, MethodRegistry};
use crate::server::updater::{
    AUTO_DEGRADE_FAILURE_THRESHOLD, UpdateDecision, UpdaterState, check_for_update,
    read_update_state,
};

/// Current RPC wire-protocol version.
///
/// Bumped only on breaking changes — fields that old clients can
/// silently ignore do not bump this. The current version is documented
/// in the iOS client's handshake and any value `>= MIN_CLIENT_PROTOCOL_VERSION`
/// is accepted.
pub const CURRENT_PROTOCOL_VERSION: u32 = 1;

/// Minimum `protocolVersion` the server will accept from a client that
/// explicitly advertises one. Clients that omit `protocolVersion` are
/// treated as pre-handshake and accepted — this is the backward-compat
/// path for the legacy iOS builds that existed before L6 landed.
pub const MIN_CLIENT_PROTOCOL_VERSION: u32 = 1;

/// Returns a pong with the current server timestamp.
///
/// When the client sends `{ protocolVersion, clientVersion? }`, the
/// handler also performs a compatibility check:
/// - `protocolVersion < MIN_CLIENT_PROTOCOL_VERSION` →
///   [`RpcError::Custom`] with code [`CLIENT_VERSION_UNSUPPORTED`] and
///   details pointing the client at the upgrade path.
/// - `protocolVersion >= MIN_CLIENT_PROTOCOL_VERSION` → success reply
///   that echoes the server's protocol version so a future client can
///   feature-gate on it.
/// - No params / no `protocolVersion` → backward-compatible reply (no
///   version fields required, no error).
pub struct PingHandler;

#[async_trait]
impl MethodHandler for PingHandler {
    #[instrument(skip(self, _ctx), fields(method = "system.ping"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let client_protocol = params
            .as_ref()
            .and_then(|p| p.get("protocolVersion"))
            .and_then(Value::as_u64)
            .map(|v| v as u32);
        let client_version = params
            .as_ref()
            .and_then(|p| p.get("clientVersion"))
            .and_then(Value::as_str)
            .map(String::from);

        if let Some(v) = client_protocol
            && v < MIN_CLIENT_PROTOCOL_VERSION
        {
            // Explicit rejection with an actionable message. Details
            // carry the numeric versions so the iOS UI can render an
            // "upgrade required" dialog with the exact numbers.
            return Err(RpcError::Custom {
                code: CLIENT_VERSION_UNSUPPORTED.to_string(),
                message: format!(
                    "Client protocol version {v} is below the minimum supported version \
                     {MIN_CLIENT_PROTOCOL_VERSION}. Please upgrade the Tron client."
                ),
                details: Some(serde_json::json!({
                    "clientProtocolVersion": v,
                    "minClientProtocolVersion": MIN_CLIENT_PROTOCOL_VERSION,
                    "serverProtocolVersion": CURRENT_PROTOCOL_VERSION,
                    "serverVersion": env!("CARGO_PKG_VERSION"),
                    "clientVersion": client_version,
                })),
            });
        }

        Ok(serde_json::json!({
            "pong": true,
            "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "serverVersion": env!("CARGO_PKG_VERSION"),
            "serverProtocolVersion": CURRENT_PROTOCOL_VERSION,
            "minClientProtocolVersion": MIN_CLIENT_PROTOCOL_VERSION,
            "compatible": true,
        }))
    }
}

/// Returns server version, platform, and capability information.
///
/// Phase 2.6 added three new fields used by the iOS pairing UI:
///
/// - `port` — the server's WebSocket listening port. iOS displays
///   `host:port` together; previously the port had to be inferred from the
///   active preset, which broke when the user typed the host without a port.
/// - `tailscaleIp` — the cached Tailscale IPv4 from
///   `~/.tron/system/settings.json:server.tailscaleIp`. Surfaced as a
///   recommended host on the iOS pairing screen. Optional — `null` when the
///   server hasn't been wrapped by `Tron.app` yet.
/// - `paired` — `true` once the `~/.tron/system/.onboarded` sentinel
///   exists. Lets iOS distinguish "fresh server, run wizard" from
///   "established server, just verify the bearer token."
///
/// All three are additive — older iOS clients that don't decode them are
/// unaffected.
pub struct GetInfoHandler;

#[async_trait]
impl MethodHandler for GetInfoHandler {
    #[instrument(skip(self, ctx), fields(method = "system.getInfo"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let uptime = ctx.server_start_time.elapsed().as_secs();
        let active_sessions = ctx.orchestrator.active_session_count();
        let tailscale_ip = crate::settings::get_settings().server.tailscale_ip.clone();
        let paired = crate::server::onboarding::is_onboarded(&ctx.onboarded_marker_path);

        Ok(serde_json::json!({
            "version": env!("CARGO_PKG_VERSION"),
            "uptime": uptime,
            "activeSessions": active_sessions,
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "runtime": "agent",
            // ── Phase 2.6 additive fields (see struct docs) ──
            "port": ctx.ws_port,
            "tailscaleIp": tailscale_ip,
            "paired": paired,
        }))
    }
}

/// Returns a structured snapshot of server state for the debug-only iOS
/// Diagnostics page. Includes server identity (version, protocol, pid,
/// uptime, origin), orchestrator counters (active sessions, active runs),
/// and the full RPC method registry grouped by prefix.
///
/// Intentionally more detailed than `system.getInfo` — the iOS settings
/// page exposes this only behind a `#if DEBUG` gate so production users
/// don't see it, but the shape is stable so a support engineer can ask
/// "send me the diagnostics JSON" and get something actionable.
pub struct GetDiagnosticsHandler;

#[async_trait]
impl MethodHandler for GetDiagnosticsHandler {
    #[instrument(skip(self, ctx), fields(method = "system.getDiagnostics"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let uptime = ctx.server_start_time.elapsed().as_secs();
        let active_sessions = ctx.orchestrator.active_session_count();
        let active_runs = ctx.orchestrator.active_run_count();

        // Build a registry on demand so the method list stays in
        // lockstep with `register_all` without any static duplication.
        // Cost: ~160 HashMap inserts. The diagnostic endpoint is called
        // manually from the debug page, not on a hot path.
        let mut reg = MethodRegistry::new();
        super::register_all(&mut reg);
        let all_methods = reg.methods();
        let total_methods = all_methods.len();

        // Group by the prefix before the first dot so the page can
        // render "session: 13, agent: 10, ..." without re-parsing.
        // BTreeMap so the groups serialize in deterministic order.
        let mut by_group: BTreeMap<String, usize> = BTreeMap::new();
        for method in &all_methods {
            let prefix = method.split('.').next().unwrap_or(method).to_string();
            *by_group.entry(prefix).or_insert(0) += 1;
        }

        Ok(serde_json::json!({
            "server": {
                "version": env!("CARGO_PKG_VERSION"),
                "protocolVersion": CURRENT_PROTOCOL_VERSION,
                "minClientProtocolVersion": MIN_CLIENT_PROTOCOL_VERSION,
                "platform": std::env::consts::OS,
                "arch": std::env::consts::ARCH,
                "pid": std::process::id(),
                "uptimeSeconds": uptime,
                "origin": ctx.origin.clone(),
            },
            "sessions": {
                "active": active_sessions,
                "activeRuns": active_runs,
            },
            "rpc": {
                "totalMethods": total_methods,
                "methodsByGroup": by_group,
                "methods": all_methods,
            },
            "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        }))
    }
}

/// Triggers a graceful shutdown of all active sessions.
pub struct ShutdownHandler;

#[async_trait]
impl MethodHandler for ShutdownHandler {
    #[instrument(skip(self, ctx), fields(method = "system.shutdown"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        ctx.orchestrator
            .shutdown()
            .await
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;
        Ok(serde_json::json!({ "acknowledged": true }))
    }
}

/// `system.probePermissions` — returns the current TCC grant state of
/// the agent process for the three wizard-surfaced permissions: Full
/// Disk Access, Screen Recording, Accessibility.
///
/// The Mac wrapper's Permissions wizard polls this handler every ~2s
/// (and on `NSApp.didBecomeActive`) to decide when to advance. The
/// whole point of doing the probe RPC-side is that the AGENT is the
/// binary the user is granting permissions to — not the wrapper —
/// because the agent runs the Computer-Use tool and the filesystem
/// tools. Probing in the wrapper would answer the wrong question.
///
/// Non-prompting: uses `AXIsProcessTrusted()` and
/// `CGPreflightScreenCaptureAccess()` FFI calls, so polling is safe
/// (it does not race the System Settings deep-link UX).
///
/// Shape:
/// ```json
/// {
///   "fullDiskAccess": "granted" | "denied" | "unknown",
///   "screenRecording": "granted" | "denied" | "unknown",
///   "accessibility":   "granted" | "denied" | "unknown"
/// }
/// ```
pub struct ProbePermissionsHandler;

#[async_trait]
impl MethodHandler for ProbePermissionsHandler {
    #[instrument(skip(self, _ctx), fields(method = "system.probePermissions"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let snapshot = crate::tools::ui::computer_use::probe_wizard_permissions().await;
        Ok(serde_json::json!({
            "fullDiskAccess":  snapshot.full_disk_access.wire_token(),
            "screenRecording": snapshot.screen_recording.wire_token(),
            "accessibility":   snapshot.accessibility.wire_token(),
        }))
    }
}

// ─────────────────────────────────────────────────────────────────────────
// User-mode auto-updater — Plan §H.2, Phase 5.5
// ─────────────────────────────────────────────────────────────────────────

/// Builds the "status + live outcome" JSON the two read-side updater
/// handlers both need to emit. Pulled into a free function so the unit
/// tests can exercise the merge logic without instantiating a handler.
///
/// `live_outcome` is the fresh check result (if one is available in the
/// current RPC) — `None` means the handler is building a pure
/// status-from-disk response.
fn build_status_value(
    current_version: &str,
    settings_update: &crate::settings::types::UpdateSettings,
    state: &UpdaterState,
    live_outcome: Option<&crate::server::updater::CheckOutcome>,
) -> Value {
    // Prefer the live outcome's resolved release if we ran one this
    // request; fall back to the state file's last-observed values so the
    // iOS settings page renders consistently between checks.
    let (latest_version, latest_download_url) = match live_outcome.and_then(|o| o.latest.as_ref()) {
        Some(r) => (Some(r.version.clone()), r.download_url.clone()),
        None => (
            state.latest_available_version.clone(),
            state.latest_download_url.clone(),
        ),
    };

    serde_json::json!({
        "currentVersion": current_version,
        "channel": settings_update.channel.as_str(),
        "frequency": settings_update.frequency.as_str(),
        "action": settings_update.action.as_str(),
        "enabled": settings_update.enabled,
        "allowDowngradeOnRollback": settings_update.allow_downgrade_on_rollback,
        "lastCheckAt": state.last_check_at,
        "lastInstalledVersion": state.last_installed_version,
        "consecutiveFailures": state.consecutive_failures,
        "autoDegradeThreshold": AUTO_DEGRADE_FAILURE_THRESHOLD,
        "latestAvailableVersion": latest_version,
        "latestDownloadUrl": latest_download_url,
    })
}

/// `system.checkForUpdates` — forces an immediate GitHub Releases check.
///
/// Early-returns `{ available: false, disabled: true, ... }` when the
/// user hasn't opted into the updater. Otherwise resolves the current
/// channel's highest semver release and compares it to
/// `env!("CARGO_PKG_VERSION")`. The response shape exactly matches the
/// iOS `SystemCheckForUpdatesResult` decoder so we don't need a
/// translation layer.
///
/// Non-goals:
/// - This handler does NOT write to `updater-state.json`. State
///   mutation is the scheduler's job (Phase 5.5 cont.); keeping the
///   handler read-only means iOS clients can poke "Check now" as often
///   as they want without racing the scheduler.
/// - No in-memory TTL cache in v1. Rate-limit concerns (Plan §N.22)
///   are hedged by the daily / weekly default frequencies; manual UI
///   presses are negligible in the per-user budget.
pub struct CheckForUpdatesHandler;

#[async_trait]
impl MethodHandler for CheckForUpdatesHandler {
    #[instrument(skip(self, ctx), fields(method = "system.checkForUpdates"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings = crate::settings::get_settings();
        let update_cfg = &settings.server.update;

        // Disabled → tell iOS so it can render the disabled banner without
        // a second round-trip. Don't touch the fetcher at all.
        if !update_cfg.enabled {
            return Ok(serde_json::json!({
                "available": false,
                "disabled": true,
                "channel": update_cfg.channel.as_str(),
                "currentVersion": env!("CARGO_PKG_VERSION"),
            }));
        }

        let Some(fetcher) = ctx.release_fetcher.as_ref() else {
            // Updater dependency not wired (e.g. embedded builds). Rather
            // than erroring — which would surface as a red toast — we
            // report "not available" so the UI degrades gracefully.
            warn!(
                "system.checkForUpdates called but RpcContext::release_fetcher is None; \
                 responding as if no release was found"
            );
            return Ok(serde_json::json!({
                "available": false,
                "disabled": false,
                "channel": update_cfg.channel.as_str(),
                "currentVersion": env!("CARGO_PKG_VERSION"),
                "unavailableReason": "fetcher-unwired",
            }));
        };

        let outcome = check_for_update(
            env!("CARGO_PKG_VERSION"),
            update_cfg.channel,
            fetcher.as_ref(),
        )
        .await
        .map_err(|e| RpcError::Internal {
            message: format!("release check failed: {e}"),
        })?;

        let available = matches!(outcome.decision, UpdateDecision::Available);

        Ok(serde_json::json!({
            "available": available,
            "disabled": false,
            "channel": update_cfg.channel.as_str(),
            "currentVersion": outcome.current_version,
            "latestVersion": outcome.latest.as_ref().map(|r| r.version.clone()),
            "downloadUrl": outcome.latest.as_ref().and_then(|r| r.download_url.clone()),
            "releaseNotes": outcome.latest.as_ref().and_then(|r| r.release_notes.clone()),
            "isPrerelease": outcome.latest.as_ref().map(|r| r.is_prerelease),
        }))
    }
}

/// `system.getUpdateStatus` — returns merged settings + state-file
/// snapshot for the iOS Settings → Updates page and the Mac menu bar's
/// updater submenu.
///
/// Deliberately does NOT call the fetcher — this is a cheap read of
/// (a) current settings via `get_settings()` (ArcSwap atomic load) and
/// (b) the updater state file via `read_update_state`. Safe to poll
/// every 2s from the iOS page without any rate-limit risk.
///
/// Reads a missing state file as the `UpdaterState::default()` so a
/// brand-new install surfaces "no check yet" instead of an error.
pub struct GetUpdateStatusHandler;

#[async_trait]
impl MethodHandler for GetUpdateStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "system.getUpdateStatus"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings = crate::settings::get_settings();
        let state_path = ctx.updater_state_path.clone();
        // read_update_state does blocking filesystem I/O; keep the
        // reactor snappy by bouncing off the blocking pool.
        let state = ctx
            .run_blocking("system.getUpdateStatus.read_state", move || {
                read_update_state(&state_path).map_err(|e| RpcError::Internal {
                    message: format!("read updater state: {e}"),
                })
            })
            .await?;

        Ok(build_status_value(
            env!("CARGO_PKG_VERSION"),
            &settings.server.update,
            &state,
            None,
        ))
    }
}

/// `system.applyUpdate` — stub in Phase 5.5.
///
/// The full install pipeline (lock `deploy.lock`, backup `.bak`,
/// atomic swap, `launchctl kickstart`, post-install ping, rollback
/// on failure) is explicitly deferred to Phase 6 per the updater
/// module docs. Returning `{ status: "noop", … }` today lets iOS
/// develop the "Install now" button against the real response shape
/// (`SystemApplyUpdateResult`) without waiting on the pipeline.
///
/// When Phase 6 lands, the noop branch gets replaced with a call to
/// the install pipeline and returns `status: "installing"` while the
/// WS streams progress events. No RPC wire-shape change required.
pub struct ApplyUpdateHandler;

#[async_trait]
impl MethodHandler for ApplyUpdateHandler {
    #[instrument(skip(self, _ctx), fields(method = "system.applyUpdate"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({
            "status": "noop",
            "message": "Install pipeline wiring lands with Phase 6 (DMG release + codesign-verify + atomic swap + rollback). \
Until then, manual DMG drag-install remains the supported upgrade path.",
            "currentVersion": env!("CARGO_PKG_VERSION"),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn ping_returns_pong() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert!(result["timestamp"].is_string());
    }

    #[tokio::test]
    async fn get_info_returns_version() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert!(result["version"].is_string());
        assert!(result["platform"].is_string());
        assert_eq!(result["runtime"], "agent");
    }

    #[tokio::test]
    async fn get_info_returns_uptime() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        let uptime = result["uptime"].as_u64().unwrap();
        assert!(uptime < 5);
    }

    #[tokio::test]
    async fn get_info_returns_active_sessions() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["activeSessions"], 1);
    }

    #[tokio::test]
    async fn get_info_retains_extra_fields() {
        let ctx = make_test_context();
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert!(result["platform"].is_string());
        assert!(result["arch"].is_string());
        assert_eq!(result["runtime"], "agent");
    }

    // ── Phase 2.6: getInfo additive fields (port, tailscaleIp, paired) ──

    /// `port` mirrors whatever the WebSocket listener bound. iOS uses this
    /// to render `host:port` together so the user never has to type the
    /// port — this test pins the contract: `port` is a number, present,
    /// and reflects whatever was wired into `RpcContext::ws_port`.
    #[tokio::test]
    async fn get_info_returns_port() {
        let mut ctx = make_test_context();
        ctx.ws_port = 19_847;
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(
            result["port"].as_u64(),
            Some(19_847),
            "port must echo ctx.ws_port (got: {:?})",
            result["port"]
        );
    }

    /// `tailscaleIp` is sourced from `settings.server.tailscaleIp` and is
    /// `null` when unset. The iOS pairing screen treats `null` as "no
    /// recommendation" rather than rendering the literal string — this
    /// test pins that nullable contract so a future refactor that
    /// accidentally substitutes `""` for `None` fails fast.
    ///
    /// Serializes against the process-global settings singleton via
    /// `test_settings_lock`. The pattern follows
    /// `server::rpc::handlers::settings`'s `SettingsTestGuard` — never
    /// call `reset_settings` mid-test (a parallel test calling
    /// `get_settings` would slow-load the *user's* real
    /// `settings.json`, contaminating the cache with whatever
    /// `tailscale_ip` is configured on the dev machine). Instead we
    /// hold the lock for the whole body and call `init_settings`
    /// directly so the slot is never `None`.
    #[tokio::test]
    async fn get_info_tailscale_ip_reflects_settings() {
        let _lock = crate::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());

        let ctx = make_test_context();

        // Case 1: setting absent → null (Option::None serializes to JSON null).
        crate::settings::init_settings(crate::settings::TronSettings::default());
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert!(
            result.get("tailscaleIp").is_some(),
            "tailscaleIp key must always be present (was: {result:?})"
        );
        assert!(
            result["tailscaleIp"].is_null(),
            "absent setting must serialize to JSON null, got: {:?}",
            result["tailscaleIp"]
        );

        // Case 2: setting populated → string value echoed verbatim.
        let mut populated = crate::settings::TronSettings::default();
        populated.server.tailscale_ip = Some("100.64.213.113".into());
        crate::settings::init_settings(populated);
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(
            result["tailscaleIp"].as_str(),
            Some("100.64.213.113"),
            "populated setting must round-trip verbatim"
        );

        // Restore defaults so any subsequent test inheriting the cache
        // sees a clean baseline (mirrors `SettingsTestGuard::drop`).
        crate::settings::init_settings(crate::settings::TronSettings::default());
    }

    /// `paired` is `true` exactly when the `.onboarded` sentinel exists at
    /// `ctx.onboarded_marker_path`. Sentinel existence is the entire signal
    /// (the file's contents are deliberately empty) — this test pins that
    /// contract end-to-end through the handler.
    #[tokio::test]
    async fn get_info_paired_reflects_sentinel() {
        let dir = tempfile::tempdir().expect("tempdir");
        let marker = dir.path().join(".onboarded");
        let mut ctx = make_test_context();
        ctx.onboarded_marker_path = marker.clone();

        // Sentinel absent → paired:false.
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(
            result["paired"], false,
            "missing sentinel must report paired:false"
        );

        // Sentinel present → paired:true.
        crate::server::onboarding::mark_onboarded(&marker).expect("mark");
        let result = GetInfoHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(
            result["paired"], true,
            "present sentinel must report paired:true"
        );
    }

    #[tokio::test]
    async fn shutdown_acknowledged() {
        let ctx = make_test_context();
        let result = ShutdownHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    /// `system.probePermissions` must return exactly the three top-level
    /// keys the Mac wrapper's `PermissionProbeRPC` decoder expects, and
    /// each value must be one of the three wire tokens — never a
    /// typo'd alias, number, or structured object. A breaking change
    /// here silently freezes the Permissions wizard at "waiting…".
    #[tokio::test]
    async fn probe_permissions_returns_three_wire_tokens() {
        let ctx = make_test_context();
        let result = ProbePermissionsHandler.handle(None, &ctx).await.unwrap();

        for key in ["fullDiskAccess", "screenRecording", "accessibility"] {
            let token = result[key].as_str().unwrap_or_else(|| {
                panic!("{key} must be a string, got {:?}", result[key])
            });
            assert!(
                matches!(token, "granted" | "denied" | "unknown"),
                "{key} must be one of granted/denied/unknown, got {token:?}",
            );
        }
    }

    #[tokio::test]
    async fn shutdown_ends_active_sessions() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"), None)
            .unwrap();
        assert_eq!(ctx.session_manager.active_count(), 1);

        let _ = ShutdownHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(ctx.session_manager.active_count(), 0);
    }

    #[tokio::test]
    async fn ping_timestamp_is_iso8601() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        let ts = result["timestamp"].as_str().unwrap();
        assert!(ts.contains('T'));
        assert!(ts.ends_with('Z'));
    }

    // ── L6: version handshake ──────────────────────────────────────

    /// Legacy clients (pre-L6) that don't advertise a protocol version
    /// must still succeed — otherwise we brick the field devices.
    #[tokio::test]
    async fn ping_without_protocol_version_is_accepted() {
        let ctx = make_test_context();
        let result = PingHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
        assert_eq!(
            result["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
    }

    /// Stale client that explicitly advertises a too-old protocol
    /// version must be rejected with CLIENT_VERSION_UNSUPPORTED and
    /// details that name both versions so the iOS UI can render an
    /// actionable upgrade prompt.
    #[tokio::test]
    async fn stale_client_rejected_with_clear_error() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": 0u32,
            "clientVersion": "0.0.1-legacy",
        });
        let err = PingHandler.handle(Some(params), &ctx).await.unwrap_err();
        assert_eq!(err.code(), CLIENT_VERSION_UNSUPPORTED);

        let body = err.to_error_body();
        assert_eq!(body.code, CLIENT_VERSION_UNSUPPORTED);
        let details = body.details.expect("details must be present");
        assert_eq!(details["clientProtocolVersion"].as_u64().unwrap(), 0);
        assert_eq!(
            details["minClientProtocolVersion"].as_u64().unwrap(),
            u64::from(MIN_CLIENT_PROTOCOL_VERSION),
        );
        assert_eq!(
            details["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
        assert_eq!(details["clientVersion"], "0.0.1-legacy");

        // Human-readable message names both numbers.
        assert!(body.message.contains("0"));
        assert!(
            body.message
                .contains(&MIN_CLIENT_PROTOCOL_VERSION.to_string())
        );
        assert!(body.message.to_lowercase().contains("upgrade"));
    }

    /// Client advertising the current protocol version receives a
    /// successful pong with `compatible: true` and the echoed protocol
    /// numbers so it can feature-gate on them.
    #[tokio::test]
    async fn current_client_accepted_with_version_echo() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": CURRENT_PROTOCOL_VERSION,
            "clientVersion": "1.2.3",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
        assert_eq!(
            result["serverProtocolVersion"].as_u64().unwrap(),
            u64::from(CURRENT_PROTOCOL_VERSION),
        );
        assert_eq!(
            result["minClientProtocolVersion"].as_u64().unwrap(),
            u64::from(MIN_CLIENT_PROTOCOL_VERSION),
        );
    }

    /// Clients from the future (higher protocol version than the
    /// server) are still accepted — the server degrades gracefully and
    /// expects the client to feature-gate on `serverProtocolVersion`.
    /// If we rejected them, rolling out a newer iOS build before the
    /// server would brick everyone.
    #[tokio::test]
    async fn future_client_is_accepted_gracefully() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": CURRENT_PROTOCOL_VERSION + 42,
            "clientVersion": "99.0.0",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
    }

    /// A client that sends garbage in `protocolVersion` (wrong type) is
    /// treated as if the field were absent — backward-compatible fail-
    /// open, not an outright rejection. The client's subsequent RPCs
    /// will fail the first time they hit a breaking change; the ping
    /// itself should not be the gate for every typo.
    #[tokio::test]
    async fn malformed_protocol_version_does_not_panic_and_accepts() {
        let ctx = make_test_context();
        let params = serde_json::json!({
            "protocolVersion": "not a number",
        });
        let result = PingHandler.handle(Some(params), &ctx).await.unwrap();
        assert_eq!(result["pong"], true);
        assert_eq!(result["compatible"], true);
    }

    // ── L11: diagnostics ────────────────────────────────────────────

    /// The envelope contract the iOS debug page relies on: `server`,
    /// `sessions`, `rpc`, `timestamp` at top level. If any of these
    /// change, the debug page breaks silently in DEBUG builds — so
    /// lock them explicitly.
    #[tokio::test]
    async fn get_diagnostics_envelope_shape() {
        let ctx = make_test_context();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();

        assert!(result["server"].is_object());
        assert!(result["sessions"].is_object());
        assert!(result["rpc"].is_object());
        assert!(result["timestamp"].is_string());
    }

    /// The RPC subsection lists every registered method. Count must
    /// match `register_all`'s method count test. If they diverge,
    /// one of them is reading a stale snapshot.
    #[tokio::test]
    async fn get_diagnostics_rpc_method_count_matches_registry() {
        let ctx = make_test_context();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();

        let total = result["rpc"]["totalMethods"].as_u64().unwrap();
        let methods = result["rpc"]["methods"].as_array().unwrap();
        assert_eq!(
            total as usize,
            methods.len(),
            "totalMethods must equal methods[].len"
        );
        // The diagnostics page renders this number as-is — a regression
        // in either count would show a wrong number to the support
        // engineer.
        let mut reg = MethodRegistry::new();
        super::super::register_all(&mut reg);
        assert_eq!(total as usize, reg.methods().len());
    }

    /// `methodsByGroup` sums to `totalMethods`. Keeps the grouping in
    /// sync with the raw list — if a regex or parser change produces
    /// "session" and "Session" as separate groups, this will fire.
    #[tokio::test]
    async fn get_diagnostics_methods_by_group_sum_matches_total() {
        let ctx = make_test_context();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();

        let total = result["rpc"]["totalMethods"].as_u64().unwrap();
        let groups = result["rpc"]["methodsByGroup"].as_object().unwrap();
        let sum: u64 = groups.values().map(|v| v.as_u64().unwrap()).sum();
        assert_eq!(
            sum, total,
            "sum of methodsByGroup values must equal totalMethods"
        );
    }

    /// `sessions.active` and `sessions.activeRuns` are non-negative
    /// integers. Regression guard against a future signed / null
    /// representation that iOS would crash on.
    #[tokio::test]
    async fn get_diagnostics_session_counts_are_u64() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["sessions"]["active"].as_u64().unwrap(), 1);
        // No runs without an agent prompt — must be 0, not null.
        assert_eq!(result["sessions"]["activeRuns"].as_u64().unwrap(), 0);
    }

    /// Server identity fields must all be present and the right shape.
    /// The debug page shows these unaltered; nulls here would confuse
    /// support.
    #[tokio::test]
    async fn get_diagnostics_server_identity_fields() {
        let ctx = make_test_context();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();
        let server = &result["server"];

        assert!(server["version"].is_string());
        assert!(server["protocolVersion"].is_u64());
        assert!(server["minClientProtocolVersion"].is_u64());
        assert!(server["platform"].is_string());
        assert!(server["arch"].is_string());
        assert!(server["pid"].is_u64());
        assert!(server["uptimeSeconds"].is_u64());
        assert!(server["origin"].is_string());
    }

    /// The diagnostics list includes `system.getDiagnostics` itself —
    /// i.e. the list is computed *after* all handlers register, so it
    /// catches handlers that registered but forgot to be added to a
    /// grouping map.
    #[tokio::test]
    async fn get_diagnostics_lists_itself() {
        let ctx = make_test_context();
        let result = GetDiagnosticsHandler.handle(None, &ctx).await.unwrap();
        let methods = result["rpc"]["methods"].as_array().unwrap();
        assert!(
            methods
                .iter()
                .any(|m| m.as_str() == Some("system.getDiagnostics")),
            "diagnostics method list must include the diagnostics method itself"
        );
    }

    // ── Phase 5.5: user-mode auto-updater RPCs ──────────────────────

    use crate::server::updater::{
        MockReleaseFetcher, ReleaseInfo, UpdateAction, UpdateChannel, UpdateFrequency,
        UpdaterState, write_update_state,
    };
    use crate::settings::{TronSettings, init_settings, test_settings_lock};
    use std::sync::Arc;

    /// Build an `UpdateSettings` with the given field overrides.
    fn cfg(
        enabled: bool,
        channel: UpdateChannel,
        frequency: UpdateFrequency,
        action: UpdateAction,
    ) -> TronSettings {
        let mut s = TronSettings::default();
        s.server.update.enabled = enabled;
        s.server.update.channel = channel;
        s.server.update.frequency = frequency;
        s.server.update.action = action;
        s
    }

    fn rel(version: &str, is_prerelease: bool, dmg_url: Option<&str>) -> ReleaseInfo {
        ReleaseInfo {
            version: version.to_string(),
            tag: format!("mac-v{version}"),
            download_url: dmg_url.map(String::from),
            release_notes: Some(format!("Notes for {version}")),
            is_prerelease,
        }
    }

    /// When `server.update.enabled = false` the handler must NOT call
    /// the fetcher and must reply with a shape iOS can decode as
    /// "no-op" (`available=false, disabled=true`). Proves the opt-in
    /// contract — a user who hasn't flipped the setting never touches
    /// github.com.
    #[tokio::test]
    async fn check_for_updates_disabled_short_circuits_fetcher() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            false,
            UpdateChannel::Stable,
            UpdateFrequency::Daily,
            UpdateAction::Notify,
        ));

        // Fetcher that would explode if called — proves we don't call it.
        let mut ctx = make_test_context();
        ctx.release_fetcher = Some(Arc::new(MockReleaseFetcher::failing(
            "test must not call fetcher",
        )));

        let result = CheckForUpdatesHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["available"], false);
        assert_eq!(result["disabled"], true);
        assert_eq!(result["channel"], "stable");

        init_settings(TronSettings::default());
    }

    /// Enabled + fetcher wired to only the *current* version → no
    /// update available. Exercises the semver-compare happy path.
    #[tokio::test]
    async fn check_for_updates_enabled_up_to_date() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            true,
            UpdateChannel::Stable,
            UpdateFrequency::Daily,
            UpdateAction::Notify,
        ));

        let mut ctx = make_test_context();
        ctx.release_fetcher = Some(Arc::new(MockReleaseFetcher::new(vec![rel(
            env!("CARGO_PKG_VERSION"),
            false,
            Some("https://example.test/Tron.dmg"),
        )])));

        let result = CheckForUpdatesHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["available"], false);
        assert_eq!(result["disabled"], false);
        assert_eq!(
            result["currentVersion"].as_str().unwrap(),
            env!("CARGO_PKG_VERSION"),
        );

        init_settings(TronSettings::default());
    }

    /// Enabled + fetcher returning a strictly-higher version → the
    /// handler signals `available=true` and propagates the DMG URL,
    /// release notes, and prerelease flag so iOS can surface them
    /// without another round-trip.
    #[tokio::test]
    async fn check_for_updates_enabled_update_available() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            true,
            UpdateChannel::Stable,
            UpdateFrequency::Daily,
            UpdateAction::Notify,
        ));

        // Build "CARGO + 1 major" so we're strictly higher regardless
        // of what patch rev we're on today.
        let current = env!("CARGO_PKG_VERSION");
        let bumped = {
            let parts: Vec<&str> = current.split('.').collect();
            let major: u32 = parts.first().and_then(|s| s.parse().ok()).unwrap_or(0);
            format!("{}.0.0", major + 99)
        };

        let mut ctx = make_test_context();
        ctx.release_fetcher = Some(Arc::new(MockReleaseFetcher::new(vec![rel(
            &bumped,
            false,
            Some("https://example.test/Tron-new.dmg"),
        )])));

        let result = CheckForUpdatesHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["available"], true);
        assert_eq!(result["disabled"], false);
        assert_eq!(result["latestVersion"].as_str().unwrap(), bumped);
        assert_eq!(
            result["downloadUrl"].as_str().unwrap(),
            "https://example.test/Tron-new.dmg",
        );
        assert!(result["releaseNotes"].as_str().unwrap().contains("Notes"));
        assert_eq!(result["isPrerelease"], false);

        init_settings(TronSettings::default());
    }

    /// Enabled but `release_fetcher = None` (embedded build / misconfig).
    /// Rather than returning an error toast, the handler reports
    /// "unavailable" with a machine-readable reason so iOS can render
    /// a disabled button silently.
    #[tokio::test]
    async fn check_for_updates_enabled_but_fetcher_missing_degrades() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            true,
            UpdateChannel::Beta,
            UpdateFrequency::Hourly,
            UpdateAction::Download,
        ));

        let mut ctx = make_test_context();
        ctx.release_fetcher = None;

        let result = CheckForUpdatesHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["available"], false);
        assert_eq!(result["disabled"], false);
        assert_eq!(result["channel"], "beta");
        assert_eq!(result["unavailableReason"], "fetcher-unwired");

        init_settings(TronSettings::default());
    }

    /// Fetcher returning a transport error is mapped to `RpcError::Internal`
    /// so the client sees a structured error rather than a hang. The
    /// post-install failure counter is NOT incremented here (only the
    /// install pipeline increments it).
    #[tokio::test]
    async fn check_for_updates_fetch_error_surfaces_as_internal_error() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            true,
            UpdateChannel::Stable,
            UpdateFrequency::Daily,
            UpdateAction::Notify,
        ));

        let mut ctx = make_test_context();
        ctx.release_fetcher = Some(Arc::new(MockReleaseFetcher::failing("boom")));

        let err = CheckForUpdatesHandler
            .handle(None, &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
        assert!(err.to_string().contains("release check failed"));

        init_settings(TronSettings::default());
    }

    /// Status reflects the current settings AND the state file
    /// verbatim. A missing state file is the common first-run case;
    /// it must NOT error and must surface as "no check yet"
    /// (all nullable fields null, `consecutiveFailures = 0`).
    #[tokio::test]
    async fn get_update_status_merges_settings_and_state() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(cfg(
            true,
            UpdateChannel::Beta,
            UpdateFrequency::Weekly,
            UpdateAction::Install,
        ));

        let dir = tempfile::tempdir().expect("tempdir");
        let state_path = dir.path().join("updater-state.json");

        // Write a realistic state file.
        let mut state = UpdaterState::default();
        state.last_check_at = Some("2026-04-23T12:00:00Z".to_string());
        state.last_installed_version = Some("0.5.0".to_string());
        state.consecutive_failures = 1;
        state.latest_available_version = Some("0.5.1".to_string());
        state.latest_download_url = Some("https://example.test/Tron-0.5.1.dmg".to_string());
        write_update_state(&state_path, &state).expect("write state");

        let mut ctx = make_test_context();
        ctx.updater_state_path = state_path;

        let result = GetUpdateStatusHandler.handle(None, &ctx).await.unwrap();

        // Settings fields flow through verbatim.
        assert_eq!(result["enabled"], true);
        assert_eq!(result["channel"], "beta");
        assert_eq!(result["frequency"], "weekly");
        assert_eq!(result["action"], "install");
        assert_eq!(result["allowDowngradeOnRollback"], true);

        // State fields flow through verbatim.
        assert_eq!(result["lastCheckAt"], "2026-04-23T12:00:00Z");
        assert_eq!(result["lastInstalledVersion"], "0.5.0");
        assert_eq!(result["consecutiveFailures"], 1);
        assert_eq!(result["latestAvailableVersion"], "0.5.1");
        assert_eq!(
            result["latestDownloadUrl"],
            "https://example.test/Tron-0.5.1.dmg"
        );

        // Contract fields iOS needs regardless of state.
        assert!(result["currentVersion"].is_string());
        assert!(result["autoDegradeThreshold"].is_u64());

        init_settings(TronSettings::default());
    }

    /// Missing state file must NOT error — first-run case. All nullable
    /// fields serialize as JSON null and `consecutiveFailures = 0`.
    #[tokio::test]
    async fn get_update_status_missing_state_file_is_fresh_defaults() {
        let _lock = test_settings_lock()
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        init_settings(TronSettings::default());

        let dir = tempfile::tempdir().expect("tempdir");
        let state_path = dir.path().join("definitely-does-not-exist.json");

        let mut ctx = make_test_context();
        ctx.updater_state_path = state_path;

        let result = GetUpdateStatusHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["consecutiveFailures"], 0);
        assert!(result["lastCheckAt"].is_null());
        assert!(result["lastInstalledVersion"].is_null());
        assert!(result["latestAvailableVersion"].is_null());
        assert!(result["latestDownloadUrl"].is_null());
        assert_eq!(result["enabled"], false); // default-off
    }

    /// `system.applyUpdate` is a stub in Phase 5.5 — it must return
    /// `status=noop` with a message explaining that the install
    /// pipeline lands in Phase 6. The iOS decoder treats `status=noop`
    /// as a non-error "not installed" outcome so users aren't misled
    /// into thinking the update succeeded.
    #[tokio::test]
    async fn apply_update_is_noop_in_phase_5_5() {
        let ctx = make_test_context();
        let result = ApplyUpdateHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["status"], "noop");
        assert!(result["message"].as_str().unwrap().to_lowercase().contains("phase 6"));
        assert!(result["currentVersion"].is_string());
    }

    /// `build_status_value` must prefer a live outcome's latest release
    /// over stale state — Phase 6's `applyUpdate` will use the same
    /// merge rule when streaming progress. Locking the precedence now
    /// means the Phase 6 refactor can't silently regress it.
    #[test]
    fn build_status_value_prefers_live_outcome_over_state() {
        use crate::server::updater::{CheckOutcome, UpdateDecision};

        let mut settings_update = crate::settings::types::UpdateSettings::default();
        settings_update.enabled = true;

        let mut state = UpdaterState::default();
        state.latest_available_version = Some("0.5.0-stale".to_string());
        state.latest_download_url = Some("https://example.test/stale.dmg".to_string());

        let live = CheckOutcome {
            current_version: "0.4.0".to_string(),
            decision: UpdateDecision::Available,
            latest: Some(rel(
                "0.5.1-fresh",
                false,
                Some("https://example.test/fresh.dmg"),
            )),
        };

        let v = build_status_value("0.4.0", &settings_update, &state, Some(&live));
        assert_eq!(v["latestAvailableVersion"], "0.5.1-fresh");
        assert_eq!(v["latestDownloadUrl"], "https://example.test/fresh.dmg");
    }

    /// Without a live outcome, `build_status_value` uses the state file
    /// — covers the `getUpdateStatus` path between scheduler ticks.
    #[test]
    fn build_status_value_falls_back_to_state_when_no_live_outcome() {
        let settings_update = crate::settings::types::UpdateSettings::default();

        let mut state = UpdaterState::default();
        state.latest_available_version = Some("0.5.0".to_string());
        state.latest_download_url = Some("https://example.test/s.dmg".to_string());

        let v = build_status_value("0.4.0", &settings_update, &state, None);
        assert_eq!(v["latestAvailableVersion"], "0.5.0");
        assert_eq!(v["latestDownloadUrl"], "https://example.test/s.dmg");
    }
}
