use super::*;
use crate::domains::settings::types::{UpdateAction, UpdateFrequency};
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
    let v = VersionId::parse("server-v0.5.0").expect("parse");
    assert_eq!(v.to_string_canonical(), "0.5.0");
}

#[test]
fn parse_with_prerelease() {
    let v = VersionId::parse("0.5.0-beta.1").expect("parse");
    assert_eq!(v.to_string_canonical(), "0.5.0-beta.1");
    assert!(v.is_prerelease());
}

#[test]
fn display_label_trims_zero_patch_and_formats_beta() {
    let v = VersionId::parse("0.1.0-beta.1").expect("parse");
    assert_eq!(v.display_label(), "v0.1 (Beta 1)");
}

#[test]
fn display_label_keeps_nonzero_patch() {
    let v = VersionId::parse("0.1.1").expect("parse");
    assert_eq!(v.display_label(), "v0.1.1");
}

#[test]
fn display_version_label_parses_scope_prefix() {
    assert_eq!(
        display_version_label("server-v0.2.0-beta.3").unwrap(),
        "v0.2 (Beta 3)"
    );
}

#[test]
fn parse_with_scope_and_prerelease() {
    let v = VersionId::parse("server-v0.5.0-beta.2").expect("parse");
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
        rel("server-v0.5.0-beta.3", "0.5.0-beta.3", true, None),
        rel("server-v0.4.9", "0.4.9", false, None),
    ];
    let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
    assert_eq!(latest.tag, "server-v0.4.9");
}

#[test]
fn beta_channel_includes_prereleases() {
    let releases = vec![
        rel("server-v0.5.0-beta.3", "0.5.0-beta.3", true, None),
        rel("server-v0.4.9", "0.4.9", false, None),
    ];
    let latest = select_latest_release(&releases, UpdateChannel::Beta).unwrap();
    // Even though beta.3 < 0.4.9? No — 0.5.0-beta.3 > 0.4.9 (major/minor dominate).
    assert_eq!(latest.tag, "server-v0.5.0-beta.3");
}

#[test]
fn stable_picks_highest_stable_even_when_beta_is_newer() {
    // Users on the stable channel should NOT see a newer beta.
    let releases = vec![
        rel("server-v0.6.0-beta.1", "0.6.0-beta.1", true, None),
        rel("server-v0.5.0", "0.5.0", false, None),
        rel("server-v0.4.9", "0.4.9", false, None),
    ];
    let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
    assert_eq!(latest.tag, "server-v0.5.0");
}

#[test]
fn empty_release_list_returns_none() {
    assert!(select_latest_release(&[], UpdateChannel::Stable).is_none());
    assert!(select_latest_release(&[], UpdateChannel::Beta).is_none());
}

#[test]
fn stable_filter_with_only_prereleases_returns_none() {
    let releases = vec![rel(
        "server-v0.5.0-beta.1",
        "0.5.0-beta.1",
        true,
        Some("u.dmg"),
    )];
    assert!(select_latest_release(&releases, UpdateChannel::Stable).is_none());
    assert_eq!(
        select_latest_release(&releases, UpdateChannel::Beta)
            .unwrap()
            .tag,
        "server-v0.5.0-beta.1"
    );
}

#[test]
fn unparseable_release_versions_are_skipped() {
    let releases = vec![
        rel("server-v0.5.0", "0.5.0", false, None),
        rel("garbage-tag", "not-a-version", false, None),
    ];
    let latest = select_latest_release(&releases, UpdateChannel::Stable).unwrap();
    // garbage-tag is skipped because VersionId::parse("not-a-version") fails.
    assert_eq!(latest.tag, "server-v0.5.0");
}

#[test]
fn github_release_mapping_accepts_only_server_tags() {
    let server = release_info_from_github(GitHubRelease {
        tag_name: "server-v0.5.1-beta.2".into(),
        body: Some("notes".into()),
        prerelease: true,
        assets: vec![GitHubAsset {
            name: "Tron-mac-v0.5.1-beta.2.dmg".into(),
            browser_download_url: "https://example.test/Tron.dmg".into(),
        }],
    })
    .expect("server tag should map");
    assert_eq!(server.version, "0.5.1-beta.2");
    assert_eq!(
        server.download_url.as_deref(),
        Some("https://example.test/Tron.dmg")
    );

    let ignored = release_info_from_github(GitHubRelease {
        tag_name: "mac-v0.5.1".into(),
        body: None,
        prerelease: false,
        assets: vec![],
    });
    assert!(
        ignored.is_none(),
        "platform-scoped tags must not drive server updates"
    );
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
    let nested = dir.path().join("nested/internal/run/updater-state.json");
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
    let release = rel("server-v0.5.1", "0.5.1", false, Some("u.dmg"));
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
    let fetcher = MockReleaseFetcher::new(vec![rel("server-v0.5.0", "0.5.0", false, None)]);
    let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
        .await
        .unwrap();
    assert_eq!(outcome.decision, UpdateDecision::UpToDate);
    assert!(outcome.latest.is_some());
}

#[tokio::test]
async fn check_reports_available_when_newer_release() {
    let fetcher = MockReleaseFetcher::new(vec![
        rel("server-v0.5.1", "0.5.1", false, Some("dmg-url")),
        rel("server-v0.5.0", "0.5.0", false, None),
    ]);
    let outcome = check_for_update("0.5.0", UpdateChannel::Stable, &fetcher)
        .await
        .unwrap();
    assert_eq!(outcome.decision, UpdateDecision::Available);
    assert_eq!(outcome.latest.as_ref().unwrap().tag, "server-v0.5.1");
}

#[tokio::test]
async fn check_reports_ahead_when_current_is_higher() {
    // Dev build: we're running 0.6.0 but latest release is 0.5.0.
    let fetcher = MockReleaseFetcher::new(vec![rel("server-v0.5.0", "0.5.0", false, None)]);
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
        rel("server-v0.5.1-beta.1", "0.5.1-beta.1", true, None),
        rel("server-v0.5.0", "0.5.0", false, None),
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
fn default_state_path_under_internal() {
    let s = updater_state_path().to_string_lossy().into_owned();
    assert!(s.ends_with("/run/updater-state.json"));
    assert!(s.contains("/.tron/internal/"));
}

#[test]
fn default_pause_path_at_tron_home() {
    let s = pause_sentinel_path().to_string_lossy().into_owned();
    assert!(s.ends_with("/.tron/internal/run/auto-update.pause"));
}
