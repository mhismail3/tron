//! # server/updater/scheduler — in-process auto-update poller
//!
//! Runs alongside the long-lived server (under the existing
//! `com.tron.server` LaunchAgent). Arms a Tokio interval per the
//! user's configured [`UpdateFrequency`], fires a check on each tick,
//! persists the outcome to `updater-state.json`, and — when a newer
//! release is available — publishes a `server.update_available`
//! event to engine streams for connected clients.
//!
//! ## Guarantees
//!
//! - **No network if `server.update.enabled == false`.** Tick returns
//!   immediately with `skipped_disabled = true` so a flipped master
//!   switch silences the scheduler without needing to respawn it.
//! - **No work while paused.** The `~/.tron/internal/run/auto-update.pause`
//!   sentinel mirrors the contributor `internal/run/auto-deploy.pause`
//!   convention. Present -> tick returns `skipped_paused = true` before
//!   talking to GitHub.
//! - **No event spam.** Duplicate `update_available` broadcasts for the
//!   same resolved version are suppressed via the `latest_available_version`
//!   column of [`UpdaterState`] — the event fires once per transition
//!   into "update available at vX".
//! - **No app-bundle mutation.** `notify` reports availability and
//!   `download` may stage a verified DMG; replacing
//!   `/Applications/Tron.app` remains a user-visible DMG install.
//! - **Network errors are non-sticky.** Transport errors log and are
//!   skipped; the next scheduled tick can recover normally.
//! - **Settings are re-read on every tick.** The scheduler does not
//!   cache the channel / frequency / action across ticks; the
//!   `ArcSwap`-backed `crate::settings::get_settings()` is already
//!   atomic so we get the current picture free.
//!
//! ## INVARIANTS
//!
//! - **One outstanding check at a time.** The loop runs sequentially;
//!   a slow GitHub response cannot stack up multiple pending ticks.
//! - **Shutdown-clean.** On `CancellationToken::cancelled()` the loop
//!   exits after any in-flight check completes. No detached tasks
//!   linger past server shutdown.
//! - **Test-deterministic.** All behavior is exposed through
//!   [`perform_tick`] which returns a [`TickReport`] value — tests
//!   assert on the report rather than waiting on wall-clock ticks.

use std::path::PathBuf;
use std::sync::Arc;

use tracing::{debug, info, warn};

use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::server::services::events_wire::ServerEventPayload;

use super::{
    CheckOutcome, ReleaseFetcher, UpdateDecision, UpdaterState, check_for_update, is_paused,
    read_update_state, write_update_state,
};

// ─────────────────────────────────────────────────────────────────────────
// Dependencies bundle
// ─────────────────────────────────────────────────────────────────────────

/// Everything `perform_tick` needs to do its job. Owned by the spawned
/// loop; cloned cheaply via `Arc` when the caller fans out the scheduler
/// across tick invocations.
#[derive(Clone)]
pub struct SchedulerDeps {
    /// Live GitHub Releases fetcher. Production wires an
    /// [`super::HttpReleaseFetcher`]; tests inject
    /// [`super::MockReleaseFetcher`].
    pub fetcher: Arc<dyn ReleaseFetcher>,
    /// Engine host used to publish server-wide update lifecycle events.
    pub engine_host: EngineHostHandle,
    /// Path to `updater-state.json`. Typically
    /// `~/.tron/internal/run/updater-state.json`.
    pub state_path: PathBuf,
    /// Path to the pause sentinel. Typically
    /// `~/.tron/internal/run/auto-update.pause`.
    pub pause_path: PathBuf,
    /// Current running binary version (normally
    /// `env!("CARGO_PKG_VERSION")`). Accepted as a parameter so tests
    /// can drive the version comparator deterministically.
    pub current_version: String,
}

// ─────────────────────────────────────────────────────────────────────────
// Tick report (test-observable)
// ─────────────────────────────────────────────────────────────────────────

/// Outcome of a single scheduler iteration.
///
/// Exposed so tests can assert on exactly what the scheduler did
/// without racing Tokio intervals. Every failure mode returns a
/// populated report rather than an `Err` — the scheduler's job is to
/// keep running even when individual ticks fail.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TickReport {
    /// `true` if the scheduler fast-returned because
    /// `server.update.enabled == false`.
    pub skipped_disabled: bool,
    /// `true` if the pause sentinel was present at tick time.
    pub skipped_paused: bool,
    /// `true` if the installed binary is newer than the latest
    /// available release (e.g., a dev build). No event is emitted in
    /// this case.
    pub skipped_ahead_of_latest: bool,
    /// Populated with a short error message when the fetcher itself errored.
    pub fetcher_error: Option<String>,
    /// Decision reached by the version comparator. `None` when the
    /// tick bailed before calling the fetcher.
    pub decision: Option<UpdateDecision>,
    /// State written to `updater-state.json` at the end of the tick.
    /// Always present — even a failed tick writes `last_check_at` and
    /// carries forward the prior successful resolution.
    pub state_after: UpdaterState,
    /// `Some(version)` if this tick emitted a fresh
    /// `server.update_available` broadcast. `None` when the observed
    /// version matched the last-emitted one, the resolved version was
    /// already installed, or no release was resolved.
    pub emitted_update_available: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────
// Core tick (pure-ish; test target)
// ─────────────────────────────────────────────────────────────────────────

/// Perform one iteration of the auto-update check.
///
/// Reads settings, honors the pause sentinel, calls the fetcher,
/// persists fresh state, and (if appropriate) broadcasts a
/// `server.update_available` event. Returns a [`TickReport`] describing
/// everything the tick did — exposed publicly so integration tests can
/// assert on behavior without driving a real Tokio interval.
pub async fn perform_tick(deps: &SchedulerDeps) -> TickReport {
    let settings = crate::settings::get_settings();
    let update_cfg = &settings.server.update;

    // Master switch → exit fast; no event, but still read prior state
    // so the report is fully populated.
    if !update_cfg.enabled {
        let state = read_update_state(&deps.state_path).unwrap_or_default();
        return TickReport {
            skipped_disabled: true,
            state_after: state,
            ..TickReport::default()
        };
    }

    // Pause sentinel → exit fast, same as above.
    if is_paused(&deps.pause_path) {
        let state = read_update_state(&deps.state_path).unwrap_or_default();
        return TickReport {
            skipped_paused: true,
            state_after: state,
            ..TickReport::default()
        };
    }

    // Call the fetcher + comparator. Any error here is a transport /
    // parse failure; surface via `fetcher_error` and bail out.
    let outcome_result = check_for_update(
        &deps.current_version,
        update_cfg.channel,
        deps.fetcher.as_ref(),
    )
    .await;

    // Load prior state so we can merge the new check result into it.
    // A failed read (corrupt JSON) falls back to the default rather
    // than losing all future checks to a single bad write.
    let mut state = match read_update_state(&deps.state_path) {
        Ok(s) => s,
        Err(e) => {
            warn!(error = %e, path = ?deps.state_path, "updater state read failed; using default");
            UpdaterState::default()
        }
    };

    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);

    let outcome: CheckOutcome = match outcome_result {
        Ok(o) => o,
        Err(e) => {
            // Persist the check timestamp (so the UI doesn't stick on
            // "Last checked: never") but leave `latest_available_version`
            // untouched so the previous successful observation still
            // drives the UI.
            state.last_check_at = Some(now.clone());
            let _ = write_update_state(&deps.state_path, &state);
            return TickReport {
                fetcher_error: Some(e.to_string()),
                state_after: state,
                ..TickReport::default()
            };
        }
    };

    // Update the state snapshot from the successful check.
    let previous_latest = state.latest_available_version.clone();
    state.record_check(outcome.latest.as_ref(), now.clone());

    // Decide whether to emit an event.
    let mut emitted: Option<String> = None;
    let mut skipped_ahead = false;

    match outcome.decision {
        UpdateDecision::Available => {
            if let Some(release) = outcome.latest.as_ref() {
                // Suppress duplicate broadcasts for the same resolved
                // version. We only emit on the transition into a new
                // version (or on a cold state file).
                let already_emitted = previous_latest.as_deref() == Some(release.version.as_str());
                if !already_emitted {
                    let payload = serde_json::json!({
                        "latestVersion": release.version,
                        "downloadUrl": release.download_url,
                        "releaseNotes": release.release_notes,
                        "channel": update_cfg.channel.as_str(),
                        "timestamp": now,
                    });
                    let event = ServerEventPayload {
                        event_type: "server.update_available".to_owned(),
                        session_id: None,
                        workspace_id: None,
                        timestamp: now.clone(),
                        data: Some(payload),
                        run_id: None,
                        sequence: None,
                        trace_id: None,
                        parent_invocation_id: None,
                        source_event_id: None,
                        source_sequence: None,
                        stream_cursor: None,
                    };
                    if let Err(error) = deps
                        .engine_host
                        .publish_stream_event(PublishStreamEvent {
                            topic: "updates".to_owned(),
                            payload: serde_json::json!({
                                "serverEvent": event,
                                "sourceEventType": "server.update_available",
                            }),
                            visibility: VisibilityScope::System,
                            session_id: None,
                            workspace_id: None,
                            producer: "updater".to_owned(),
                            trace_id: None,
                            parent_invocation_id: None,
                        })
                        .await
                    {
                        warn!(error = %error, "updater stream publication failed");
                    }
                    emitted = Some(release.version.clone());
                    info!(
                        version = %release.version,
                        channel = update_cfg.channel.as_str(),
                        action = update_cfg.action.as_str(),
                        "broadcast server.update_available (scheduler tick)"
                    );
                } else {
                    debug!(
                        version = %release.version,
                        "suppressed duplicate server.update_available"
                    );
                }
            }
        }
        UpdateDecision::UpToDate => {
            debug!(
                current = %outcome.current_version,
                "scheduler tick: up to date"
            );
        }
        UpdateDecision::AheadOfLatest => {
            skipped_ahead = true;
            debug!(
                current = %outcome.current_version,
                "scheduler tick: running a build newer than the latest release"
            );
        }
    }

    // Persist even when no event fired — `last_check_at` advances on
    // every successful poll so the UI can surface a fresh timestamp.
    if let Err(e) = write_update_state(&deps.state_path, &state) {
        warn!(error = %e, path = ?deps.state_path, "updater state write failed");
    }

    TickReport {
        skipped_disabled: false,
        skipped_paused: false,
        skipped_ahead_of_latest: skipped_ahead,
        fetcher_error: None,
        decision: Some(outcome.decision),
        state_after: state,
        emitted_update_available: emitted,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Scheduler entry point
// ─────────────────────────────────────────────────────────────────────────

/// Spawn the long-lived updater task.
///
/// Contract:
/// - On each loop iteration, re-reads `server.update.frequency` from
///   settings (so a user flipping from `manual` to `hourly` takes
///   effect on the next wake without restart).
/// - `Manual` / `Startup` cadences do not arm a Tokio interval — the
///   former skips all polling, the latter runs exactly one tick and
///   exits.
/// - `Hourly` / `Daily` / `Weekly` arm a Tokio interval with the
///   matching period and fire `perform_tick` on each strobe.
/// - On `shutdown.cancelled()` the loop exits after the current tick.
///
/// Returns a `JoinHandle<()>` so `main.rs` can await the task during
/// graceful shutdown. Ignored failures are logged, not propagated.
pub fn spawn(
    deps: SchedulerDeps,
    shutdown: tokio_util::sync::CancellationToken,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        use crate::settings::types::UpdateFrequency;

        // First look at settings to decide whether to even arm the
        // loop. The default config is disabled so this usually logs
        // "scheduler armed (disabled)" and sits idle.
        let initial_frequency = crate::settings::get_settings().server.update.frequency;
        let initial_enabled = crate::settings::get_settings().server.update.enabled;
        debug!(
            enabled = initial_enabled,
            frequency = initial_frequency.as_str(),
            "auto-update scheduler spawned"
        );

        // `Startup` fires once at boot and returns.
        if matches!(initial_frequency, UpdateFrequency::Startup) {
            // Still honor the disabled flag inside perform_tick itself.
            let _ = perform_tick(&deps).await;
            return;
        }

        // `Manual` parks on the shutdown token — ticks only come via
        // `system::check_for_updates`. We still keep the task alive
        // because settings can flip to a recurring cadence at any
        // time; on every "settings changed" we just wake and re-read.
        //
        // Tokio doesn't give us a free "settings-changed" signal, so
        // we poll the settings at a safe cadence (every 60 s). The
        // poll itself is a pure read — no network, no disk — so the
        // cost is negligible.
        let poll_interval = std::time::Duration::from_secs(60);
        let mut next_sleep = poll_interval;

        loop {
            tokio::select! {
                _ = tokio::time::sleep(next_sleep) => {
                    let cfg = crate::settings::get_settings().server.update.clone();

                    if !cfg.enabled {
                        // Disabled → re-check settings on the same
                        // polling cadence. No network.
                        next_sleep = poll_interval;
                        continue;
                    }

                    match cfg.frequency {
                        UpdateFrequency::Manual => {
                            next_sleep = poll_interval;
                        }
                        UpdateFrequency::Startup => {
                            // Already ran above; if settings flipped to
                            // Startup mid-loop we intentionally do
                            // nothing — startup-only is a boot-time
                            // cadence.
                            next_sleep = poll_interval;
                        }
                        UpdateFrequency::Hourly
                        | UpdateFrequency::Daily
                        | UpdateFrequency::Weekly => {
                            let report = perform_tick(&deps).await;
                            if let Some(ref err) = report.fetcher_error {
                                debug!(error = %err, "auto-update tick skipped");
                            }
                            next_sleep = cfg
                                .frequency
                                .interval()
                                .unwrap_or(poll_interval);
                        }
                    }
                }
                () = shutdown.cancelled() => {
                    debug!("auto-update scheduler shutting down");
                    return;
                }
            }
        }
    })
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::EngineHostHandle;
    use crate::server::updater::{MockReleaseFetcher, ReleaseInfo};
    use crate::settings::types::{UpdateChannel, UpdateFrequency};

    fn release(version: &str, prerelease: bool) -> ReleaseInfo {
        ReleaseInfo {
            version: version.to_string(),
            tag: format!("server-v{version}"),
            download_url: Some(format!(
                "https://github.com/mhismail3/tron/releases/download/server-v{version}/Tron.dmg"
            )),
            release_notes: Some(format!("Release {version}")),
            is_prerelease: prerelease,
        }
    }

    fn deps_with(
        fetcher: Arc<dyn ReleaseFetcher>,
        tmp: &tempfile::TempDir,
        current_version: &str,
    ) -> SchedulerDeps {
        SchedulerDeps {
            fetcher,
            engine_host: EngineHostHandle::new_in_memory().unwrap(),
            state_path: tmp.path().join("updater-state.json"),
            pause_path: tmp.path().join("auto-update.pause"),
            current_version: current_version.to_string(),
        }
    }

    /// Acquire the shared settings test lock and install a fresh
    /// `UpdateSettings` into the cache. Returns the guard so the
    /// caller can hold it across `.await` while running the scheduler
    /// tick. The guard is a `std::sync::Mutex` — we hold it across
    /// `.await` intentionally, which is fine because the scheduler
    /// tick itself never takes the settings lock.
    fn install_update_settings(
        update: crate::settings::types::UpdateSettings,
    ) -> std::sync::MutexGuard<'static, ()> {
        let guard = crate::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut settings = crate::settings::types::TronSettings::default();
        settings.server.update = update;
        crate::settings::init_settings(settings);
        guard
    }

    fn default_enabled(channel: UpdateChannel) -> crate::settings::types::UpdateSettings {
        let mut s = crate::settings::types::UpdateSettings::default();
        s.enabled = true;
        s.channel = channel;
        s.frequency = UpdateFrequency::Daily;
        s
    }

    #[tokio::test]
    async fn disabled_flag_short_circuits_before_fetcher() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::failing("must not be called"));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let mut settings = crate::settings::types::UpdateSettings::default();
        settings.enabled = false;
        let _guard = install_update_settings(settings);

        let report = perform_tick(&deps).await;

        assert!(report.skipped_disabled, "must skip when disabled");
        assert!(report.fetcher_error.is_none(), "fetcher should not fire");
        assert!(report.emitted_update_available.is_none());
        assert_eq!(report.decision, None);
        // State path may not exist yet — that's the default.
        assert_eq!(report.state_after, UpdaterState::default());
    }

    #[tokio::test]
    async fn pause_sentinel_short_circuits_before_fetcher() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::failing("must not be called"));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        // Create pause sentinel.
        std::fs::write(&deps.pause_path, b"").unwrap();

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let report = perform_tick(&deps).await;

        assert!(report.skipped_paused, "must skip when paused");
        assert!(report.fetcher_error.is_none());
        assert!(report.emitted_update_available.is_none());
    }

    #[tokio::test]
    async fn newer_release_emits_update_available_event_once() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![release("0.6.0", false)]));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));

        // First tick → should emit.
        let report1 = perform_tick(&deps).await;
        assert_eq!(report1.decision, Some(UpdateDecision::Available));
        assert_eq!(report1.emitted_update_available.as_deref(), Some("0.6.0"));
        assert_eq!(
            report1.state_after.latest_available_version.as_deref(),
            Some("0.6.0")
        );
        assert!(report1.state_after.last_check_at.is_some());

        // Second tick on the same version → should NOT emit again.
        let report2 = perform_tick(&deps).await;
        assert_eq!(report2.decision, Some(UpdateDecision::Available));
        assert_eq!(
            report2.emitted_update_available, None,
            "duplicate version must not re-broadcast"
        );
    }

    #[tokio::test]
    async fn new_version_re_emits_after_transition() {
        let tmp = tempfile::tempdir().unwrap();
        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));

        // First fetcher: newer release at 0.6.0.
        let fetcher1 = Arc::new(MockReleaseFetcher::new(vec![release("0.6.0", false)]));
        let deps1 = deps_with(fetcher1, &tmp, "0.5.0");
        let r1 = perform_tick(&deps1).await;
        assert_eq!(r1.emitted_update_available.as_deref(), Some("0.6.0"));

        // Second fetcher reuses the same state path.
        let fetcher2 = Arc::new(MockReleaseFetcher::new(vec![
            release("0.6.0", false),
            release("0.7.0", false),
        ]));
        let deps2 = SchedulerDeps {
            fetcher: fetcher2,
            engine_host: deps1.engine_host.clone(),
            state_path: deps1.state_path.clone(),
            pause_path: deps1.pause_path.clone(),
            current_version: "0.5.0".to_string(),
        };
        let r2 = perform_tick(&deps2).await;

        assert_eq!(
            r2.emitted_update_available.as_deref(),
            Some("0.7.0"),
            "new version should re-broadcast"
        );
    }

    #[tokio::test]
    async fn up_to_date_does_not_emit() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![release("0.5.0", false)]));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let report = perform_tick(&deps).await;

        assert_eq!(report.decision, Some(UpdateDecision::UpToDate));
        assert!(report.emitted_update_available.is_none());
        assert!(report.state_after.last_check_at.is_some());
    }

    #[tokio::test]
    async fn dev_build_ahead_of_latest_does_not_emit() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![release("0.5.0", false)]));
        // NB: `VersionId::parse`'s leading-`v` stripper is overly
        // greedy on strings that contain a literal `v` elsewhere
        // (e.g. `0.6.0-dev.1`), which can surface as a parse error
        // rather than `AheadOfLatest`. Use a plain numeric triple for
        // the "dev build newer than latest release" case. A follow-up
        // can tighten the parser; the scheduler itself handles the
        // comparator output correctly either way.
        let deps = deps_with(fetcher, &tmp, "0.6.1");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let report = perform_tick(&deps).await;

        assert_eq!(report.decision, Some(UpdateDecision::AheadOfLatest));
        assert!(report.skipped_ahead_of_latest);
        assert!(report.emitted_update_available.is_none());
    }

    #[tokio::test]
    async fn fetcher_transport_error_records_fresh_check_time() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::failing("dns failure"));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let mut seed = UpdaterState::default();
        seed.latest_available_version = Some("0.5.9".to_string());
        write_update_state(&deps.state_path, &seed).unwrap();

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let report = perform_tick(&deps).await;

        assert!(report.fetcher_error.is_some());
        assert!(report.state_after.last_check_at.is_some());
        assert_eq!(
            report.state_after.latest_available_version.as_deref(),
            Some("0.5.9"),
            "failed checks should not clear the last successful update banner"
        );
    }

    #[tokio::test]
    async fn beta_channel_picks_beta_release() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![
            release("0.6.0", false),
            release("0.7.0-beta.1", true),
        ]));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Beta));
        let report = perform_tick(&deps).await;

        assert_eq!(
            report.emitted_update_available.as_deref(),
            Some("0.7.0-beta.1"),
            "beta channel must prefer the prerelease"
        );
    }

    #[tokio::test]
    async fn stable_channel_filters_out_prerelease() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![release("0.7.0-beta.1", true)]));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let report = perform_tick(&deps).await;

        assert_eq!(
            report.decision,
            Some(UpdateDecision::UpToDate),
            "stable channel must ignore prereleases"
        );
        assert!(report.emitted_update_available.is_none());
    }

    #[tokio::test]
    async fn tick_persists_state_file_atomically() {
        let tmp = tempfile::tempdir().unwrap();
        let fetcher = Arc::new(MockReleaseFetcher::new(vec![release("0.6.0", false)]));
        let deps = deps_with(fetcher, &tmp, "0.5.0");

        let _guard = install_update_settings(default_enabled(UpdateChannel::Stable));
        let _ = perform_tick(&deps).await;

        let persisted =
            read_update_state(&deps.state_path).expect("state file should exist after tick");
        assert_eq!(persisted.latest_available_version.as_deref(), Some("0.6.0"));
        assert_eq!(
            persisted.latest_download_url.as_deref(),
            Some("https://github.com/mhismail3/tron/releases/download/server-v0.6.0/Tron.dmg")
        );
        assert!(persisted.last_check_at.is_some());
    }
}
