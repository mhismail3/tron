//! # server/updater — user-mode GitHub Releases auto-updater
//!
//! The server-side half of the user-facing update-check flow.
//! Distinct from the contributor-focused `scripts/auto-deploy` loop:
//! that one pulls from `origin/main` via git and `tron deploy --force`
//! and requires a cloned repository. This module operates on installed
//! `Tron.app` bundles produced by the Mac DMG release pipeline — it
//! polls the GitHub Releases API, compares the published version to
//! the running server, and emits the appropriate events / state
//! transitions based on the user's configured action.
//!
//! ## What this module owns
//!
//! - **`run/updater-state.json`** at
//!   [`crate::core::paths::updater_state_path()`]. Durable record of
//!   the last check timestamp, the last installed version, and a
//!   reserved failure counter for future app-bundle updater work.
//!   Mode `0o644` (non-secret); atomic writes via the same
//!   `tempfile + sync_all + rename` pattern used for `auth.json`
//!   so readers never observe a torn file.
//! - **`auto-update.pause`** sentinel at
//!   [`crate::core::paths::auto_update_pause_path()`]. Mirrors the
//!   contributor `auto-deploy.pause` convention: the file's presence
//!   blocks update actions without mutating settings.
//! - **Pure-value primitives** — `UpdateChannel`, `UpdateAction`,
//!   `UpdateFrequency` enums; `UpdaterState` (and its serde layout);
//!   `compare_versions` (semver-lite for the CARGO_PKG_VERSION
//!   convention used by the project, including `-beta.N` pre-releases);
//!   `select_latest_release` (resolves the best release for a channel
//!   from a list returned by the fetcher).
//! - **`ReleaseFetcher` trait** — one-shot GitHub Releases lookup.
//!   Implementations: `HttpReleaseFetcher` (live GitHub API) and
//!   `MockReleaseFetcher` (test-only, in-memory roster). The trait
//!   boundary keeps the pure comparator testable without network
//!   access.
//!
//! ## INVARIANTS
//!
//! - **State file is atomic.** Concurrent readers always see either
//!   the pre-write or post-write JSON, never a partial. Writes use
//!   `tempfile::Builder::tempfile_in → sync_all → persist` and land
//!   in the same directory so `rename(2)` is atomic on every POSIX
//!   filesystem (the same guarantee exercised by
//!   `atomic_write_no_partial_under_concurrent_readers` in
//!   `server::onboarding`).
//! - **State writes are serialized** through a process-wide mutex so
//!   two simultaneous `write_update_state` calls cannot race. Reads
//!   are lock-free — they rely purely on `rename`'s atomicity.
//! - **Version comparison is total.** Every `Cargo.toml` version the
//!   project might produce parses through `VersionId::parse` cleanly;
//!   pre-release tags order strictly less than the equivalent stable
//!   (so `1.2.3-beta.1 < 1.2.3`). Invalid inputs return an error so
//!   the updater can refuse to act rather than guessing.
//! - **Channel filter is conservative.** On the `Stable` channel the
//!   fetcher consumer strips any pre-release entries before comparing
//!   so `notify`/`download` never fires on a `beta.N` build
//!   for a user who didn't opt in.
//! - **No app-bundle mutation.** Production updates stop at notifying
//!   the user with the release download URL. Installing remains a
//!   user-visible DMG replacement of `/Applications/Tron.app` until a
//!   full app-bundle updater is designed.
//!
//! ## Submodules
//!
//! Currently a single-file module. If app-bundle updating is added,
//! split out:
//! - `fetcher_http.rs` — the live GitHub Releases fetcher.
//! - `install.rs` — the signed app-bundle replacement pipeline.

#![deny(unsafe_code)]

use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use async_trait::async_trait;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

pub mod scheduler;

pub use scheduler::{SchedulerDeps, TickReport, perform_tick};

// ─────────────────────────────────────────────────────────────────────────
// Public path helpers
// ─────────────────────────────────────────────────────────────────────────

/// Default path for the updater's durable state file.
pub fn updater_state_path() -> PathBuf {
    crate::core::paths::updater_state_path()
}

/// Default path for the pause sentinel.
pub fn pause_sentinel_path() -> PathBuf {
    crate::core::paths::auto_update_pause_path()
}

/// Returns `true` when the pause sentinel exists.
pub fn is_paused(path: &Path) -> bool {
    path.exists()
}

/// Create the pause sentinel. Idempotent — creating an existing sentinel
/// is a no-op.
pub fn pause(path: &Path) -> io::Result<()> {
    if path.exists() {
        return Ok(());
    }
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "pause sentinel path has no parent directory",
        )
    })?;
    std::fs::create_dir_all(parent)?;
    std::fs::write(path, b"")
}

/// Remove the pause sentinel. Idempotent — removing an absent sentinel
/// is a no-op.
pub fn resume(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Enumerations
// ─────────────────────────────────────────────────────────────────────────

/// Release channel the user subscribes to. Determines which GitHub
/// releases the updater considers when resolving "latest".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    /// Only releases without a pre-release suffix (e.g. `mac-v0.5.0`,
    /// not `mac-v0.5.0-beta.1`). The safe default.
    #[default]
    Stable,
    /// All releases, including pre-releases. Used by early adopters
    /// and by dogfood Macs that want to catch regressions before the
    /// stable channel sees them.
    Beta,
}

impl UpdateChannel {
    /// Wire-format string used in RPC responses and the state file.
    /// Mirrors the `#[serde(rename_all = "lowercase")]` casing so a
    /// consumer can compare against `"stable"` / `"beta"` without
    /// re-serializing.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Beta => "beta",
        }
    }
}

/// Cadence at which the in-process scheduler fires an update check.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateFrequency {
    /// No automatic checks. Only fired by an explicit
    /// `system.checkForUpdates` RPC. Useful for iOS-only operators
    /// who don't want their Mac to do background work.
    Manual,
    /// One check at server startup.
    Startup,
    /// One check every hour.
    Hourly,
    /// One check every day (the safe default — balances timeliness
    /// against GitHub API rate-limit headroom).
    #[default]
    Daily,
    /// One check every week.
    Weekly,
}

impl UpdateFrequency {
    /// Wire-format string used in RPC responses.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Startup => "startup",
            Self::Hourly => "hourly",
            Self::Daily => "daily",
            Self::Weekly => "weekly",
        }
    }

    /// Scheduler interval for a non-manual / non-startup cadence.
    /// `Manual` and `Startup` have no recurring interval and return
    /// `None` — the scheduler uses this to decide whether to arm a
    /// Tokio interval at all.
    pub fn interval(&self) -> Option<std::time::Duration> {
        use std::time::Duration;
        match self {
            Self::Manual | Self::Startup => None,
            Self::Hourly => Some(Duration::from_secs(60 * 60)),
            Self::Daily => Some(Duration::from_secs(24 * 60 * 60)),
            Self::Weekly => Some(Duration::from_secs(7 * 24 * 60 * 60)),
        }
    }
}

/// What the updater does when it observes a newer release.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateAction {
    /// Emit an `update_available` event with release notes + download
    /// URL; leave the install to the user. The conservative default.
    #[default]
    Notify,
}

impl UpdateAction {
    /// Wire-format string used in RPC responses.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Notify => "notify",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// UpdaterState (persisted JSON)
// ─────────────────────────────────────────────────────────────────────────

/// Durable state written to `~/.tron/system/run/updater-state.json`.
///
/// Read on every server start, written on every successful check or
/// install attempt. Fields are individually optional so the on-disk
/// schema can grow additively without breaking older readers.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UpdaterState {
    /// ISO 8601 timestamp of the last completed check (success or
    /// failure). `None` until the first check runs.
    pub last_check_at: Option<String>,
    /// Semantic version of the last release observed as installed by a
    /// future app-bundle updater. Current production updates are DMG
    /// replacement, so this usually stays `None`.
    pub last_installed_version: Option<String>,
    /// Last observed "latest available" version from a successful
    /// check. Cleared when `last_installed_version` catches up. The
    /// Mac menu bar + iOS settings page render a "Up to date" vs
    /// "Update available — vX" row from this.
    pub latest_available_version: Option<String>,
    /// Download URL for the `latest_available_version`, if the last
    /// check resolved one. Opaque string that should NOT be
    /// re-derived from `latest_available_version` + a URL template;
    /// GitHub's URL scheme is stable but not contractually so.
    pub latest_download_url: Option<String>,
}

impl UpdaterState {
    /// Mark a successful check that observed `latest` as the best
    /// release on the current channel. Updates `last_check_at` to
    /// now and stashes the resolved URL.
    pub fn record_check(&mut self, latest: Option<&ReleaseInfo>, now_rfc3339: String) {
        self.last_check_at = Some(now_rfc3339);
        self.latest_available_version = latest.map(|r| r.version.clone());
        self.latest_download_url = latest.and_then(|r| r.download_url.clone());
    }
}

// ─────────────────────────────────────────────────────────────────────────
// State file I/O
// ─────────────────────────────────────────────────────────────────────────

/// Read the updater state from `path`. Returns `UpdaterState::default()`
/// when the file is absent — first-boot case. Any other read error or a
/// malformed JSON body bubbles up so the caller can choose to fail open
/// (log and use the default) or fail closed (refuse to start).
pub fn read_update_state(path: &Path) -> io::Result<UpdaterState> {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(UpdaterState::default()),
        Err(e) => return Err(e),
    };
    serde_json::from_str::<UpdaterState>(&raw)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Persist the updater state to `path` atomically.
///
/// Serialized through a process-wide mutex so two concurrent callers
/// cannot race on the file. The rename itself is POSIX-atomic so
/// concurrent readers always observe a consistent snapshot.
pub fn write_update_state(path: &Path, state: &UpdaterState) -> io::Result<()> {
    let _guard = write_lock().lock();
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "updater-state path has no parent directory",
        )
    })?;
    std::fs::create_dir_all(parent)?;
    atomic_write(parent, path, json.as_bytes())
}

fn atomic_write(parent: &Path, final_path: &Path, contents: &[u8]) -> io::Result<()> {
    let mut tmp = tempfile::Builder::new()
        .prefix(".updater-state.tmp.")
        .tempfile_in(parent)?;
    tmp.write_all(contents)?;
    tmp.as_file().sync_all()?;
    let _persisted = tmp.persist(final_path).map_err(|e| e.error)?;
    Ok(())
}

fn write_lock() -> &'static Mutex<()> {
    use std::sync::OnceLock;
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

// ─────────────────────────────────────────────────────────────────────────
// Version comparison
// ─────────────────────────────────────────────────────────────────────────

/// A parsed semver-lite version triple with optional pre-release tag.
///
/// Accepted shapes:
/// - `1.2.3`
/// - `1.2.3-beta.1`
/// - `v1.2.3` (leading `v` is stripped)
/// - `mac-v1.2.3-beta.1` (GitHub Release tag form — everything up to
///   the last `v` is treated as a scope prefix and stripped)
///
/// Comparison follows the obvious semver rules: numeric triples
/// lexicographically, then a release WITHOUT a pre-release tag sorts
/// strictly GREATER than the same triple WITH one. Pre-release tags
/// compare lexicographically (so `beta.10 > beta.2` — good enough for
/// now; a follow-up can split on `.` to get numeric comparison of
/// `beta.N` components).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct VersionId {
    major: u64,
    minor: u64,
    patch: u64,
    /// `None` means "no pre-release tag" — sorts greater than any
    /// `Some(...)`. To make `Ord` agree with that intent we store
    /// `Option<String>` and rely on `Option`'s derived ordering
    /// (where `None > Some`), which is the opposite of what we want,
    /// so we wrap it in a helper type: see `PreRelease`.
    pre: PreRelease,
}

/// Wrapper that inverts `Option<String>` ordering so a pre-release
/// sorts strictly less than its parent release. `PreRelease(None)`
/// is the "no tag / stable" flavor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreRelease(Option<String>);

impl PartialOrd for PreRelease {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for PreRelease {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        match (&self.0, &other.0) {
            (None, None) => Ordering::Equal,
            // No pre-release > any pre-release tag (stable > beta).
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(a), Some(b)) => compare_pre_tokens(a, b),
        }
    }
}

/// Compare two pre-release labels token by token (split on `.`) so
/// `beta.10 > beta.2` rather than the lexicographic `beta.10 < beta.2`.
fn compare_pre_tokens(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let mut ai = a.split('.');
    let mut bi = b.split('.');
    loop {
        match (ai.next(), bi.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) => {
                let ord = match (x.parse::<u64>(), y.parse::<u64>()) {
                    (Ok(xi), Ok(yi)) => xi.cmp(&yi),
                    _ => x.cmp(y),
                };
                if ord != Ordering::Equal {
                    return ord;
                }
            }
        }
    }
}

/// Parse error for [`VersionId::parse`]. Opaque string — callers
/// surface it to logs only, not to users.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VersionParseError(pub String);

impl std::fmt::Display for VersionParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid version: {}", self.0)
    }
}

impl std::error::Error for VersionParseError {}

impl VersionId {
    /// Parse a version string. See the type-level doc for accepted
    /// shapes.
    pub fn parse(raw: &str) -> Result<Self, VersionParseError> {
        // Strip any scope prefix up to and including the last `v`,
        // then strip a lone leading `v` for the `v1.2.3` form.
        let stripped = match raw.rfind('v') {
            Some(idx) => &raw[idx + 1..],
            None => raw,
        };
        let (triple, pre) = match stripped.split_once('-') {
            Some((t, p)) => (t, Some(p.to_string())),
            None => (stripped, None),
        };
        let mut parts = triple.split('.');
        let major = parts
            .next()
            .ok_or_else(|| VersionParseError(raw.to_string()))?
            .parse::<u64>()
            .map_err(|_| VersionParseError(raw.to_string()))?;
        let minor = parts
            .next()
            .ok_or_else(|| VersionParseError(raw.to_string()))?
            .parse::<u64>()
            .map_err(|_| VersionParseError(raw.to_string()))?;
        let patch = parts
            .next()
            .ok_or_else(|| VersionParseError(raw.to_string()))?
            .parse::<u64>()
            .map_err(|_| VersionParseError(raw.to_string()))?;
        if parts.next().is_some() {
            // More than three dotted components — reject rather than
            // silently truncate.
            return Err(VersionParseError(raw.to_string()));
        }
        Ok(Self {
            major,
            minor,
            patch,
            pre: PreRelease(pre),
        })
    }

    /// Return the canonical rendering (`major.minor.patch[-pre]`).
    pub fn to_string_canonical(&self) -> String {
        match &self.pre.0 {
            Some(p) => format!("{}.{}.{}-{}", self.major, self.minor, self.patch, p),
            None => format!("{}.{}.{}", self.major, self.minor, self.patch),
        }
    }

    /// `true` when this version carries a pre-release suffix.
    pub fn is_prerelease(&self) -> bool {
        self.pre.0.is_some()
    }
}

/// Decision from a version check. Used to drive event / action
/// selection in the calling code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpdateDecision {
    /// Installed version is >= latest. No action.
    UpToDate,
    /// A newer release is available.
    Available,
    /// Installed version is newer than the latest release (e.g., a
    /// dev build). No action — the updater refuses to downgrade.
    AheadOfLatest,
}

/// Compare the currently running version against the latest
/// observed. Always handles equal + newer cases safely.
pub fn compare_versions(current: &VersionId, latest: &VersionId) -> UpdateDecision {
    use std::cmp::Ordering;
    match current.cmp(latest) {
        Ordering::Less => UpdateDecision::Available,
        Ordering::Equal => UpdateDecision::UpToDate,
        Ordering::Greater => UpdateDecision::AheadOfLatest,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Release fetcher
// ─────────────────────────────────────────────────────────────────────────

/// Summary of a single GitHub release. The fetcher implementations
/// convert the API response into this shape so the rest of the
/// updater doesn't depend on `octocrab` / raw `reqwest` types.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReleaseInfo {
    /// Parsed version (already stripped of the `mac-v` scope prefix
    /// and any leading `v`).
    pub version: String,
    /// The original GitHub Release `tag_name` (e.g. `mac-v0.5.0`).
    /// Kept around so telemetry / logs can cite the exact tag the
    /// fetcher resolved against.
    pub tag: String,
    /// Direct download URL for the Mac DMG asset attached to this
    /// release. `None` when the release exists but has no matching
    /// `.dmg` asset (in-flight release, CI failure, etc.).
    pub download_url: Option<String>,
    /// Markdown release notes, verbatim from GitHub. `None` if the
    /// release has no body.
    pub release_notes: Option<String>,
    /// `true` if this release is flagged `prerelease` in the API
    /// response. The `Stable` channel filter drops these.
    pub is_prerelease: bool,
}

/// Abstraction over "fetch the list of releases from GitHub". Lets
/// tests inject deterministic rosters while the live implementation
/// hits the real API.
#[async_trait]
pub trait ReleaseFetcher: Send + Sync {
    /// Return every release the implementation knows about, newest
    /// first (or in no particular order — `select_latest_release`
    /// does the sort itself).
    async fn list_releases(&self) -> Result<Vec<ReleaseInfo>, FetchError>;
}

/// Fetcher error surface. Opaque by design — the updater handles
/// all variants the same way (log + skip the check).
#[derive(Debug)]
pub enum FetchError {
    /// Transport-level failure (DNS, TCP, TLS, connection reset).
    Transport(String),
    /// Non-2xx HTTP response including rate-limit / 404 / 5xx.
    Http {
        /// HTTP status code returned by the GitHub API.
        status: u16,
        /// Body fragment for diagnostics. Truncated by the
        /// fetcher implementation so this never holds an
        /// unbounded string.
        body: String,
    },
    /// Malformed response JSON.
    Parse(String),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(m) => write!(f, "updater transport error: {m}"),
            Self::Http { status, body } => {
                write!(f, "updater http error: status={status}, body={body}")
            }
            Self::Parse(m) => write!(f, "updater parse error: {m}"),
        }
    }
}

impl std::error::Error for FetchError {}

/// Pick the best release for a given channel from a list returned by
/// the fetcher. Returns `None` when no release matches (empty list,
/// or all candidates filtered out because they're pre-releases on
/// the `Stable` channel).
///
/// Tie-breaks: if two releases parse to the same version, the first
/// one in the input order wins. GitHub returns releases newest-first
/// by publication date, so in practice that's always the desired
/// behavior.
pub fn select_latest_release(
    releases: &[ReleaseInfo],
    channel: UpdateChannel,
) -> Option<&ReleaseInfo> {
    releases
        .iter()
        .filter(|r| match channel {
            UpdateChannel::Stable => !r.is_prerelease,
            UpdateChannel::Beta => true,
        })
        .filter_map(|r| VersionId::parse(&r.version).ok().map(|v| (v, r)))
        .max_by(|(a, _), (b, _)| a.cmp(b))
        .map(|(_, r)| r)
}

// ─────────────────────────────────────────────────────────────────────────
// In-memory test fetcher
// ─────────────────────────────────────────────────────────────────────────

/// Deterministic in-memory `ReleaseFetcher` for tests.
#[derive(Clone, Debug)]
pub struct MockReleaseFetcher {
    releases: Vec<ReleaseInfo>,
    fail_with: Option<String>,
}

impl MockReleaseFetcher {
    /// Build a new mock with the given release roster.
    pub fn new(releases: Vec<ReleaseInfo>) -> Self {
        Self {
            releases,
            fail_with: None,
        }
    }

    /// Construct a mock that always returns a transport error.
    pub fn failing(message: impl Into<String>) -> Self {
        Self {
            releases: Vec::new(),
            fail_with: Some(message.into()),
        }
    }
}

#[async_trait]
impl ReleaseFetcher for MockReleaseFetcher {
    async fn list_releases(&self) -> Result<Vec<ReleaseInfo>, FetchError> {
        if let Some(msg) = &self.fail_with {
            return Err(FetchError::Transport(msg.clone()));
        }
        Ok(self.releases.clone())
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Orchestration
// ─────────────────────────────────────────────────────────────────────────

/// Outcome of a single `check_for_update` call. Matches the shape
/// the `system.checkForUpdates` RPC surfaces to iOS / the Mac menu
/// bar; the event layer wraps this in `server.update_available`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckOutcome {
    /// Current running version. Always the `CARGO_PKG_VERSION`
    /// or an explicitly injected string (in tests).
    pub current_version: String,
    /// The comparator's decision. Drives iOS UI affordances.
    pub decision: UpdateDecision,
    /// Resolved latest release, if any. `None` when the channel has
    /// no releases at all.
    pub latest: Option<ReleaseInfo>,
}

/// Run a single check through the provided fetcher. Pure in the
/// sense that it doesn't mutate disk state on its own — callers
/// that want persistence call `record_check` on their `UpdaterState`
/// and write it back explicitly. That separation keeps the test
/// surface small.
pub async fn check_for_update(
    current_version: &str,
    channel: UpdateChannel,
    fetcher: &dyn ReleaseFetcher,
) -> Result<CheckOutcome, FetchError> {
    let current = VersionId::parse(current_version)
        .map_err(|e| FetchError::Parse(format!("invalid current version: {e}")))?;
    let releases = fetcher.list_releases().await?;
    let latest_ref = select_latest_release(&releases, channel);
    let decision = match latest_ref {
        Some(r) => match VersionId::parse(&r.version) {
            Ok(v) => compare_versions(&current, &v),
            Err(e) => return Err(FetchError::Parse(format!("invalid release version: {e}"))),
        },
        None => UpdateDecision::UpToDate,
    };
    Ok(CheckOutcome {
        current_version: current_version.to_string(),
        decision,
        latest: latest_ref.cloned(),
    })
}

// ─────────────────────────────────────────────────────────────────────────
// Live GitHub Releases fetcher
// ─────────────────────────────────────────────────────────────────────────

/// Live `ReleaseFetcher` backed by the public GitHub REST API.
///
/// Targets the `mhismail3/tron` repository by default — the configured
/// release home for the project. Uses an unauthenticated client, which
/// caps requests at 60/hour/IP; for the expected cadence (daily check
/// per user) this is well under the limit. If rate-limit pressure ever
/// becomes real, we'll ship a read-only PAT in release builds to raise
/// the cap to 5000/hour.
///
/// A single shared `reqwest::Client` is reused across calls to keep
/// connection pooling warm. The fetcher itself is a thin wrapper over
/// `GET /repos/:owner/:repo/releases`.
pub struct HttpReleaseFetcher {
    client: reqwest::Client,
    repo: String,
}

impl HttpReleaseFetcher {
    /// Construct a fetcher targeting the default `mhismail3/tron`
    /// repository.
    pub fn new() -> Self {
        Self::for_repo("mhismail3/tron")
    }

    /// Construct a fetcher targeting an explicit `owner/repo` slug.
    /// Primarily used by tests that want to hit a fixture server.
    pub fn for_repo(repo: impl Into<String>) -> Self {
        // 10-second network timeout keeps the check from blocking the
        // scheduler for minutes if GitHub is down. On transport failure
        // the check is simply skipped.
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .user_agent(concat!("tron-agent/", env!("CARGO_PKG_VERSION")))
            .build()
            // reqwest::Client::build is infallible for the features we
            // enable; a panic here would indicate a missing TLS backend
            // in the build, which is a real bug not a runtime condition.
            .expect("reqwest client construction must succeed");
        Self {
            client,
            repo: repo.into(),
        }
    }
}

impl Default for HttpReleaseFetcher {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl ReleaseFetcher for HttpReleaseFetcher {
    async fn list_releases(&self) -> Result<Vec<ReleaseInfo>, FetchError> {
        let url = format!("https://api.github.com/repos/{}/releases", self.repo);
        let resp = self
            .client
            .get(&url)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|e| FetchError::Transport(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            // Cap body fragment so a 500KB error page doesn't blow up
            // the log buffer.
            let body = resp.text().await.unwrap_or_default();
            let truncated = body.chars().take(512).collect::<String>();
            return Err(FetchError::Http {
                status: status.as_u16(),
                body: truncated,
            });
        }

        let raw: Vec<GitHubRelease> = resp
            .json()
            .await
            .map_err(|e| FetchError::Parse(e.to_string()))?;

        Ok(raw.into_iter().map(Into::into).collect())
    }
}

/// Subset of the GitHub Releases API response we consume.
#[derive(Debug, Deserialize)]
struct GitHubRelease {
    /// Git tag associated with the release (e.g. `mac-v0.5.0`).
    tag_name: String,
    /// Release notes in Markdown.
    body: Option<String>,
    /// `true` for pre-releases (betas).
    #[serde(default)]
    prerelease: bool,
    /// Uploaded release assets. We pluck the `.dmg` URL from here.
    #[serde(default)]
    assets: Vec<GitHubAsset>,
}

/// Subset of a GitHub release asset. Only `name` + download URL matter.
#[derive(Debug, Deserialize)]
struct GitHubAsset {
    name: String,
    /// Browser-facing direct-download URL. This is the one users (and
    /// the install pipeline) want — `url` without `_download_` goes
    /// through a 302 redirect and requires extra header handling.
    browser_download_url: String,
}

impl From<GitHubRelease> for ReleaseInfo {
    fn from(raw: GitHubRelease) -> Self {
        // Normalize the tag → version: `mac-v0.5.0` → `0.5.0`.
        let version = match raw.tag_name.rfind('v') {
            Some(idx) => raw.tag_name[idx + 1..].to_string(),
            None => raw.tag_name.clone(),
        };
        // Pick the first `.dmg` asset we see. The release workflow
        // currently publishes a single DMG per release.
        let download_url = raw
            .assets
            .into_iter()
            .find(|a| a.name.to_lowercase().ends_with(".dmg"))
            .map(|a| a.browser_download_url);
        Self {
            version,
            tag: raw.tag_name,
            download_url,
            release_notes: raw.body,
            is_prerelease: raw.prerelease,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread;
    use std::time::Duration;

    // ── Version parsing ──

    #[test]
    fn parse_triple() {
        let v = VersionId::parse("1.2.3").expect("parse");
        assert_eq!(v.to_string_canonical(), "1.2.3");
        assert!(!v.is_prerelease());
    }

    #[test]
    fn parse_with_v_prefix() {
        let v = VersionId::parse("v0.5.0").expect("parse");
        assert_eq!(v.to_string_canonical(), "0.5.0");
    }

    #[test]
    fn parse_with_scope_prefix() {
        let v = VersionId::parse("mac-v0.5.0").expect("parse");
        assert_eq!(v.to_string_canonical(), "0.5.0");
    }

    #[test]
    fn parse_with_prerelease() {
        let v = VersionId::parse("0.5.0-beta.1").expect("parse");
        assert_eq!(v.to_string_canonical(), "0.5.0-beta.1");
        assert!(v.is_prerelease());
    }

    #[test]
    fn parse_with_scope_and_prerelease() {
        let v = VersionId::parse("mac-v0.5.0-beta.2").expect("parse");
        assert_eq!(v.to_string_canonical(), "0.5.0-beta.2");
        assert!(v.is_prerelease());
    }

    #[test]
    fn parse_rejects_too_many_components() {
        assert!(VersionId::parse("1.2.3.4").is_err());
    }

    #[test]
    fn parse_rejects_non_numeric() {
        assert!(VersionId::parse("1.x.3").is_err());
        assert!(VersionId::parse("abc").is_err());
        assert!(VersionId::parse("").is_err());
    }

    #[test]
    fn parse_rejects_missing_components() {
        assert!(VersionId::parse("1.2").is_err());
        assert!(VersionId::parse("1").is_err());
    }

    // ── Version ordering ──

    #[test]
    fn ordering_major_minor_patch() {
        let lower = VersionId::parse("1.2.3").unwrap();
        let upper = VersionId::parse("1.2.4").unwrap();
        assert!(lower < upper);
        let upper = VersionId::parse("1.3.0").unwrap();
        assert!(lower < upper);
        let upper = VersionId::parse("2.0.0").unwrap();
        assert!(lower < upper);
    }

    #[test]
    fn prerelease_sorts_less_than_stable() {
        let pre = VersionId::parse("0.5.0-beta.1").unwrap();
        let stable = VersionId::parse("0.5.0").unwrap();
        assert!(pre < stable, "beta.1 must sort below stable 0.5.0");
    }

    #[test]
    fn prerelease_tokens_are_numeric_aware() {
        // `beta.10` > `beta.2` — the naive string sort would have
        // `beta.10 < beta.2`. Guard against regressing to that.
        let older = VersionId::parse("0.5.0-beta.2").unwrap();
        let newer = VersionId::parse("0.5.0-beta.10").unwrap();
        assert!(
            older < newer,
            "beta.10 must sort above beta.2, got older={older:?} newer={newer:?}"
        );
    }

    #[test]
    fn prerelease_tokens_mixed() {
        let alpha = VersionId::parse("0.5.0-alpha.1").unwrap();
        let beta = VersionId::parse("0.5.0-beta.1").unwrap();
        assert!(alpha < beta);
    }

    #[test]
    fn compare_produces_decision() {
        let cur = VersionId::parse("0.5.0").unwrap();
        let same = VersionId::parse("0.5.0").unwrap();
        let newer = VersionId::parse("0.5.1").unwrap();
        let older = VersionId::parse("0.4.9").unwrap();
        assert_eq!(compare_versions(&cur, &same), UpdateDecision::UpToDate);
        assert_eq!(compare_versions(&cur, &newer), UpdateDecision::Available);
        assert_eq!(
            compare_versions(&cur, &older),
            UpdateDecision::AheadOfLatest
        );
    }

    // ── Channel selection ──

    fn rel(tag: &str, ver: &str, pre: bool, url: Option<&str>) -> ReleaseInfo {
        ReleaseInfo {
            version: ver.to_string(),
            tag: tag.to_string(),
            download_url: url.map(String::from),
            release_notes: None,
            is_prerelease: pre,
        }
    }

    #[test]
    fn stable_channel_ignores_prereleases() {
        let releases = vec![
            rel("mac-v0.5.0-beta.3", "0.5.0-beta.3", true, None),
            rel("mac-v0.4.9", "0.4.9", false, None),
        ];
        let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
        assert_eq!(latest.tag, "mac-v0.4.9");
    }

    #[test]
    fn beta_channel_includes_prereleases() {
        let releases = vec![
            rel("mac-v0.5.0-beta.3", "0.5.0-beta.3", true, None),
            rel("mac-v0.4.9", "0.4.9", false, None),
        ];
        let latest = select_latest_release(&releases, UpdateChannel::Beta).unwrap();
        // Even though beta.3 < 0.4.9? No — 0.5.0-beta.3 > 0.4.9 (major/minor dominate).
        assert_eq!(latest.tag, "mac-v0.5.0-beta.3");
    }

    #[test]
    fn stable_picks_highest_stable_even_when_beta_is_newer() {
        // Users on the stable channel should NOT see a newer beta.
        let releases = vec![
            rel("mac-v0.6.0-beta.1", "0.6.0-beta.1", true, None),
            rel("mac-v0.5.0", "0.5.0", false, None),
            rel("mac-v0.4.9", "0.4.9", false, None),
        ];
        let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
        assert_eq!(latest.tag, "mac-v0.5.0");
    }

    #[test]
    fn empty_release_list_returns_none() {
        assert!(select_latest_release(&[], UpdateChannel::Stable).is_none());
        assert!(select_latest_release(&[], UpdateChannel::Beta).is_none());
    }

    #[test]
    fn stable_filter_with_only_prereleases_returns_none() {
        let releases = vec![rel(
            "mac-v0.5.0-beta.1",
            "0.5.0-beta.1",
            true,
            Some("u.dmg"),
        )];
        assert!(select_latest_release(&releases, UpdateChannel::Stable).is_none());
        assert_eq!(
            select_latest_release(&releases, UpdateChannel::Beta)
                .unwrap()
                .tag,
            "mac-v0.5.0-beta.1"
        );
    }

    #[test]
    fn unparseable_release_versions_are_skipped() {
        let releases = vec![
            rel("mac-v0.5.0", "0.5.0", false, None),
            rel("garbage-tag", "not-a-version", false, None),
        ];
        let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
        // garbage-tag is skipped because VersionId::parse("not-a-version") fails.
        assert_eq!(latest.tag, "mac-v0.5.0");
    }

    // ── State serde + I/O ──

    fn temp_state_path() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("updater-state.json");
        (dir, path)
    }

    #[test]
    fn state_default_is_empty() {
        let s = UpdaterState::default();
        assert!(s.last_check_at.is_none());
        assert!(s.last_installed_version.is_none());
        assert!(s.latest_available_version.is_none());
        assert!(s.latest_download_url.is_none());
    }

    #[test]
    fn state_serde_camel_case() {
        let mut s = UpdaterState::default();
        s.last_check_at = Some("2026-04-23T12:00:00.000Z".into());
        s.last_installed_version = Some("0.5.0".into());
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("lastCheckAt").is_some(), "got {json:?}");
        assert!(json.get("lastInstalledVersion").is_some(), "got {json:?}");
        assert!(json.get("consecutiveFailures").is_none(), "got {json:?}");
    }

    #[test]
    fn state_read_absent_returns_default() {
        let (_dir, path) = temp_state_path();
        assert!(!path.exists());
        let s = read_update_state(&path).unwrap();
        assert_eq!(s, UpdaterState::default());
    }

    #[test]
    fn state_read_malformed_returns_error() {
        let (_dir, path) = temp_state_path();
        std::fs::write(&path, "not json").unwrap();
        let err = read_update_state(&path).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn state_write_then_read_roundtrips() {
        let (_dir, path) = temp_state_path();
        let mut s = UpdaterState::default();
        s.last_installed_version = Some("0.4.9".into());
        write_update_state(&path, &s).unwrap();
        let back = read_update_state(&path).unwrap();
        assert_eq!(back, s);
    }

    #[test]
    fn state_write_creates_parent_dir() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("nested/system/run/updater-state.json");
        write_update_state(&nested, &UpdaterState::default()).unwrap();
        assert!(nested.exists());
    }

    #[cfg(unix)]
    #[test]
    fn state_file_is_owner_readable() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, path) = temp_state_path();
        write_update_state(&path, &UpdaterState::default()).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        // The state file has no secrets — `tempfile::Builder` opens
        // with `0o600` by default which is fine for our case (the
        // server runs as the same user that wrote the file). We don't
        // pin a stricter shape than "owner can read it" so this test
        // doesn't break if a future revision widens the perms.
        assert!(
            mode & 0o400 == 0o400,
            "state must be at least owner-readable, got {mode:o}"
        );
    }

    #[test]
    fn state_record_check_populates_fields() {
        let mut s = UpdaterState::default();
        let release = rel("mac-v0.5.1", "0.5.1", false, Some("u.dmg"));
        s.record_check(Some(&release), "2026-04-23T00:00:00Z".into());
        assert_eq!(s.last_check_at.as_deref(), Some("2026-04-23T00:00:00Z"));
        assert_eq!(s.latest_available_version.as_deref(), Some("0.5.1"));
        assert_eq!(s.latest_download_url.as_deref(), Some("u.dmg"));
    }

    #[test]
    fn state_record_check_no_latest_clears_fields() {
        let mut s = UpdaterState {
            latest_available_version: Some("0.5.1".into()),
            latest_download_url: Some("u.dmg".into()),
            ..Default::default()
        };
        s.record_check(None, "2026-04-23T00:00:00Z".into());
        assert!(s.latest_available_version.is_none());
        assert!(s.latest_download_url.is_none());
    }

    #[test]
    fn concurrent_writes_serialize() {
        // Eight threads write distinct states. The mutex serializes them;
        // the final file parses cleanly and matches one of the writers'
        // inputs byte-for-byte.
        let (_dir, path) = temp_state_path();
        let path = Arc::new(path);
        let mut handles = Vec::new();
        for i in 0..8 {
            let p = Arc::clone(&path);
            handles.push(thread::spawn(move || {
                let mut s = UpdaterState::default();
                s.last_installed_version = Some(format!("0.{i}.0"));
                write_update_state(&p, &s).unwrap();
                s
            }));
        }
        let written: Vec<UpdaterState> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let final_state = read_update_state(&path).unwrap();
        assert!(
            written.contains(&final_state),
            "final state must equal one of the writer payloads"
        );
    }

    #[test]
    fn atomic_write_no_partial_under_concurrent_readers() {
        // Mirrors `server::onboarding`'s torn-read guard: reader thread
        // spins on `read_update_state` while the writer thread
        // overwrites 100 times. Reader must never see an I/O error or
        // a partially-written file.
        let (_dir, path) = temp_state_path();
        let path = Arc::new(path);

        // Seed with a known-good state.
        write_update_state(&path, &UpdaterState::default()).unwrap();

        let stop = Arc::new(AtomicBool::new(false));
        let reader_path = Arc::clone(&path);
        let reader_stop = Arc::clone(&stop);
        let bad = Arc::new(AtomicUsize::new(0));
        let bad_reader = Arc::clone(&bad);
        let reader = thread::spawn(move || {
            while !reader_stop.load(Ordering::Relaxed) {
                match read_update_state(&reader_path) {
                    Ok(_) => {}
                    Err(_) => {
                        bad_reader.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        });

        for i in 0..100 {
            let mut s = UpdaterState::default();
            s.last_check_at = Some(format!("2026-04-23T00:00:{i:02}Z"));
            write_update_state(&path, &s).unwrap();
        }
        thread::sleep(Duration::from_millis(20));
        stop.store(true, Ordering::Relaxed);
        reader.join().unwrap();
        assert_eq!(
            bad.load(Ordering::Relaxed),
            0,
            "concurrent reader observed a torn file"
        );
    }

    // ── check_for_update ──

    #[tokio::test]
    async fn check_reports_up_to_date_when_latest_matches() {
        let fetcher = MockReleaseFetcher::new(vec![rel("mac-v0.5.0", "0.5.0", false, None)]);
        let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::UpToDate);
        assert!(outcome.latest.is_some());
    }

    #[tokio::test]
    async fn check_reports_available_when_newer_release() {
        let fetcher = MockReleaseFetcher::new(vec![
            rel("mac-v0.5.1", "0.5.1", false, Some("dmg-url")),
            rel("mac-v0.5.0", "0.5.0", false, None),
        ]);
        let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::Available);
        assert_eq!(outcome.latest.as_ref().unwrap().tag, "mac-v0.5.1");
    }

    #[tokio::test]
    async fn check_reports_ahead_when_current_is_higher() {
        // Dev build: we're running 0.6.0 but latest release is 0.5.0.
        let fetcher = MockReleaseFetcher::new(vec![rel("mac-v0.5.0", "0.5.0", false, None)]);
        let outcome = check_for_update("0.6.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::AheadOfLatest);
    }

    #[tokio::test]
    async fn check_is_up_to_date_when_no_releases() {
        let fetcher = MockReleaseFetcher::new(Vec::new());
        let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::UpToDate);
        assert!(outcome.latest.is_none());
    }

    #[tokio::test]
    async fn check_respects_channel() {
        let fetcher = MockReleaseFetcher::new(vec![
            rel("mac-v0.5.1-beta.1", "0.5.1-beta.1", true, None),
            rel("mac-v0.5.0", "0.5.0", false, None),
        ]);
        // Stable user: beta ignored, so 0.5.0 is still "latest".
        let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::UpToDate);
        // Beta user: beta is available.
        let outcome = check_for_update("0.5.0", UpdateChannel::Beta, &fetcher)
            .await
            .unwrap();
        assert_eq!(outcome.decision, UpdateDecision::Available);
    }

    #[tokio::test]
    async fn check_surfaces_transport_errors() {
        let fetcher = MockReleaseFetcher::failing("dns failure");
        let err = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap_err();
        assert!(
            matches!(err, FetchError::Transport(_)),
            "got {err:?} wanted Transport"
        );
    }

    #[tokio::test]
    async fn check_rejects_invalid_current_version() {
        let fetcher = MockReleaseFetcher::new(vec![]);
        let err = check_for_update("not-a-version", UpdateChannel::Stable, &fetcher)
            .await
            .unwrap_err();
        assert!(matches!(err, FetchError::Parse(_)), "got {err:?}");
    }

    // ── Pause sentinel ──

    #[test]
    fn pause_sentinel_roundtrips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auto-update.pause");
        assert!(!is_paused(&path));
        pause(&path).unwrap();
        assert!(is_paused(&path));
        // Idempotent re-pause.
        pause(&path).unwrap();
        resume(&path).unwrap();
        assert!(!is_paused(&path));
        // Idempotent re-resume.
        resume(&path).unwrap();
    }

    #[test]
    fn pause_creates_missing_parent() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("nested/dir/auto-update.pause");
        pause(&nested).unwrap();
        assert!(nested.exists());
    }

    // ── Enum defaults and serde ──

    #[test]
    fn channel_defaults_to_stable() {
        assert_eq!(UpdateChannel::default(), UpdateChannel::Stable);
    }

    #[test]
    fn action_defaults_to_notify() {
        assert_eq!(UpdateAction::default(), UpdateAction::Notify);
    }

    #[test]
    fn frequency_defaults_to_daily() {
        assert_eq!(UpdateFrequency::default(), UpdateFrequency::Daily);
    }

    #[test]
    fn channel_serde_lowercase() {
        assert_eq!(
            serde_json::to_string(&UpdateChannel::Stable).unwrap(),
            "\"stable\""
        );
        assert_eq!(
            serde_json::to_string(&UpdateChannel::Beta).unwrap(),
            "\"beta\""
        );
        let back: UpdateChannel = serde_json::from_str("\"beta\"").unwrap();
        assert_eq!(back, UpdateChannel::Beta);
    }

    #[test]
    fn action_serde_lowercase() {
        assert_eq!(
            serde_json::to_string(&UpdateAction::Notify).unwrap(),
            "\"notify\""
        );
        let back: UpdateAction = serde_json::from_str("\"notify\"").unwrap();
        assert_eq!(back, UpdateAction::Notify);
        assert!(serde_json::from_str::<UpdateAction>("\"download\"").is_err());
    }

    #[test]
    fn frequency_serde_lowercase() {
        assert_eq!(
            serde_json::to_string(&UpdateFrequency::Hourly).unwrap(),
            "\"hourly\""
        );
        let back: UpdateFrequency = serde_json::from_str("\"weekly\"").unwrap();
        assert_eq!(back, UpdateFrequency::Weekly);
    }

    // ── Path helpers ──

    #[test]
    fn default_state_path_under_system() {
        let s = updater_state_path().to_string_lossy().into_owned();
        assert!(s.ends_with("/run/updater-state.json"));
        assert!(s.contains("/.tron/system/"));
    }

    #[test]
    fn default_pause_path_at_tron_home() {
        let s = pause_sentinel_path().to_string_lossy().into_owned();
        assert!(s.ends_with("/.tron/auto-update.pause"));
    }
}
