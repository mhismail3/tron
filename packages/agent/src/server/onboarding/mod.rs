//! # server/onboarding — bearer-token lifecycle + first-run sentinel
//!
//! Per-server bootstrap state: bearer-token lifecycle and first-run sentinel.
//!
//! ## What this module owns
//!
//! - **`auth.json.bearerToken`** at [`crate::core::paths::auth_path()`].
//!   A single 32-byte URL-safe-base64 token that gates WebSocket upgrade
//!   requests. Generated during first server startup; rotated via
//!   `tron auth rotate` (CLI) or the
//!   menu-bar action in the Mac wrapper. File mode is `0o600` and writes
//!   are owned by `llm::auth::storage` so provider credentials and the
//!   pairing bearer share one secure auth document.
//!
//! - **`run/.onboarded`** sentinel at [`crate::core::paths::onboarded_marker_path()`].
//!   Empty marker file. Touched by the Mac wizard at the end of its
//!   install flow OR on the first successful WS auth. The
//!   `system.getInfo` RPC returns `paired: true` once it exists so iOS
//!   can detect "this server has already been paired with someone."
//!
//! ## INVARIANTS
//!
//! - Bearer token is exactly 32 random bytes encoded as URL-safe base64
//!   without padding (43 chars). The encoding choice means the token is
//!   safe to embed verbatim in a `tron://pair?token=…` deep link without
//!   percent-encoding.
//! - `auth.json` is never world-readable. The 0o600 perms are set by
//!   `llm::auth::storage` at `open(2)` time, before any bytes are
//!   written; the atomic `rename` preserves them.
//! - Rotation is serialized through a per-process mutex so two
//!   concurrent `rotate_bearer_token` calls cannot corrupt the file.
//!   Concurrent reads see a consistent snapshot via the atomic rename
//!   (mirrors the `auth.json` invariant tested in `auth/storage.rs`).
//! - Sentinel creation is idempotent: `mark_onboarded` on an existing
//!   marker is a no-op, never an error.
//!
//! ## Submodules
//!
//! Currently a single-file module — submodules will be added as the
//! onboarding surface grows (e.g. pairing-token TTL, device registry).

#![deny(unsafe_code)]

use std::io;
use std::path::{Path, PathBuf};

use base64::{Engine as _, engine::general_purpose};
use parking_lot::Mutex;
use rand::RngCore;

use crate::llm::auth::errors::AuthError;
use crate::llm::auth::storage::{load_auth_storage, load_or_init_for_write, save_auth_storage};

/// Length of the raw random token in bytes. Encoded as URL-safe base64
/// without padding, this produces a 43-character string.
const TOKEN_BYTE_LEN: usize = 32;

/// Expected length of the encoded token string. 32 bytes × 8 bits ÷ 6
/// bits-per-base64-char = 42.67, rounded up to 43. The `URL_SAFE_NO_PAD`
/// alphabet drops the trailing `=` characters that would normally pad to
/// a multiple of 4.
const ENCODED_TOKEN_LEN: usize = 43;

/// Default file path for the bearer token: `~/.tron/profiles/auth.json`.
pub fn bearer_token_path() -> PathBuf {
    crate::core::paths::auth_path()
}

/// Default file path for the first-run sentinel: `~/.tron/internal/run/.onboarded`.
pub fn onboarded_marker_path() -> PathBuf {
    crate::core::paths::onboarded_marker_path()
}

/// Generate a fresh bearer token: 32 cryptographic-random bytes encoded
/// as URL-safe base64 without padding (43 ASCII characters).
///
/// Uses `rand::rng()` (the OS-backed thread-local RNG) so each call is
/// independent and suitable for cryptographic use.
pub fn generate_bearer_token() -> String {
    let mut bytes = [0u8; TOKEN_BYTE_LEN];
    rand::rng().fill_bytes(&mut bytes);
    let token = general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    debug_assert_eq!(
        token.len(),
        ENCODED_TOKEN_LEN,
        "URL_SAFE_NO_PAD encoding of {TOKEN_BYTE_LEN} bytes must yield {ENCODED_TOKEN_LEN} chars"
    );
    token
}

/// Load the existing bearer token from `path`, or generate + persist a
/// new one if the file is absent.
///
/// Called at server startup so the daemon always has a token to compare
/// against incoming `Authorization: Bearer` headers. The first call after
/// install creates the file; every subsequent boot reads it back.
pub fn load_or_create_bearer_token(path: &Path) -> io::Result<String> {
    if let Some(existing) = read_token(path)? {
        return Ok(existing);
    }
    let _guard = rotate_lock().lock();
    if let Some(existing) = read_token(path)? {
        return Ok(existing);
    }
    let mut storage = load_or_init_for_write(path).map_err(auth_error_to_io)?;
    let token = generate_bearer_token();
    storage.bearer_token = Some(token.clone());
    save_auth_storage(path, &mut storage).map_err(auth_error_to_io)?;
    Ok(token)
}

/// Replace the stored bearer token with a fresh one. Returns the new
/// token so the caller can display it (CLI) or push a notification
/// (RPC).
///
/// Serialized through a process-wide mutex so two concurrent rotations
/// cannot corrupt the file. The file write itself is also atomic
/// (tempfile → sync → rename), so concurrent readers always see either
/// the old or the new token, never a partial.
pub fn rotate_bearer_token(path: &Path) -> io::Result<String> {
    let _guard = rotate_lock().lock();
    let mut storage = load_or_init_for_write(path).map_err(auth_error_to_io)?;
    let token = generate_bearer_token();
    storage.bearer_token = Some(token.clone());
    save_auth_storage(path, &mut storage).map_err(auth_error_to_io)?;
    Ok(token)
}

/// Returns true when the first-run sentinel marker exists at `path`.
///
/// Used by `system.getInfo` to populate the `paired` field. Existence
/// is the entire signal — the file's contents are deliberately empty.
pub fn is_onboarded(path: &Path) -> bool {
    path.exists()
}

/// Create the first-run sentinel marker at `path`. Idempotent: a no-op
/// if the file already exists.
///
/// Touched by the Mac wizard at the end of its install flow and (TBD
/// in Phase 3) on the first successful iOS bearer auth.
pub fn mark_onboarded(path: &Path) -> io::Result<()> {
    if path.exists() {
        return Ok(());
    }
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "onboarded marker path has no parent directory",
        )
    })?;
    std::fs::create_dir_all(parent)?;
    std::fs::write(path, b"")
}

// ─────────────────────────────────────────────────────────────────────────
// Internals
// ─────────────────────────────────────────────────────────────────────────

/// Read the stored token from `auth.json`, returning `None` if the file
/// or `bearerToken` field is absent. Returns `Err` for any other I/O
/// failure or malformed JSON.
fn read_token(path: &Path) -> io::Result<Option<String>> {
    let Some(storage) = load_auth_storage(path).map_err(auth_error_to_io)? else {
        return Ok(None);
    };
    Ok(storage
        .bearer_token
        .and_then(|token| non_empty_token(&token).map(str::to_owned)))
}

fn non_empty_token(token: &str) -> Option<&str> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn auth_error_to_io(err: AuthError) -> io::Error {
    match err {
        AuthError::Io(e) => e,
        other => io::Error::new(io::ErrorKind::InvalidData, other),
    }
}

/// Process-wide rotation mutex. Two concurrent `rotate_bearer_token`
/// calls serialize through this so they cannot race on the file write.
fn rotate_lock() -> &'static Mutex<()> {
    use std::sync::OnceLock;
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::Duration;

    fn temp_token_path() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("auth.json");
        (dir, path)
    }

    fn temp_marker_path() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(".onboarded");
        (dir, path)
    }

    // ── Token generation ──

    #[test]
    fn generate_returns_url_safe_base64_of_expected_length() {
        let token = generate_bearer_token();
        assert_eq!(
            token.len(),
            ENCODED_TOKEN_LEN,
            "expected {ENCODED_TOKEN_LEN} chars for 32 random bytes"
        );
        // URL-safe alphabet: A-Z a-z 0-9 - _
        assert!(
            token
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
            "token must use URL-safe alphabet, got: {token}"
        );
        // No padding.
        assert!(
            !token.contains('='),
            "URL_SAFE_NO_PAD must not emit padding"
        );
    }

    #[test]
    fn two_consecutive_tokens_differ() {
        let a = generate_bearer_token();
        let b = generate_bearer_token();
        assert_ne!(
            a, b,
            "two consecutive tokens must differ (probability ~1 in 2^256)"
        );
    }

    #[test]
    fn one_thousand_tokens_are_unique() {
        // Probabilistic guard: 32-byte tokens collide with vanishingly
        // small probability. A failure here means the RNG is broken.
        let mut seen = HashSet::with_capacity(1000);
        for _ in 0..1000 {
            let t = generate_bearer_token();
            assert!(seen.insert(t), "RNG produced a duplicate inside 1000 calls");
        }
    }

    // ── load_or_create ──

    #[test]
    fn load_or_create_writes_when_absent() {
        let (_dir, path) = temp_token_path();
        assert!(!path.exists());
        let token = load_or_create_bearer_token(&path).expect("create");
        assert_eq!(token.len(), ENCODED_TOKEN_LEN);
        assert!(path.exists());
    }

    #[test]
    fn load_or_create_returns_existing_when_present() {
        let (_dir, path) = temp_token_path();
        let first = load_or_create_bearer_token(&path).expect("first call creates");
        let second = load_or_create_bearer_token(&path).expect("second call reads");
        assert_eq!(
            first, second,
            "second load must return the same persisted token"
        );
    }

    #[test]
    fn load_or_create_returns_error_for_malformed_file() {
        let (_dir, path) = temp_token_path();
        std::fs::write(&path, "not json").expect("seed bad file");
        let err = load_or_create_bearer_token(&path).expect_err("malformed must fail");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn load_or_create_initializes_missing_token_field() {
        let (_dir, path) = temp_token_path();
        std::fs::write(
            &path,
            r#"{"version":1,"providers":{},"lastUpdated":"2026-04-27T00:00:00Z"}"#,
        )
        .expect("seed");
        let token = load_or_create_bearer_token(&path).expect("missing bearerToken initializes");
        assert_eq!(token.len(), ENCODED_TOKEN_LEN);
        let raw = std::fs::read_to_string(&path).expect("read auth.json");
        let parsed: serde_json::Value = serde_json::from_str(&raw).expect("auth json");
        assert_eq!(parsed["bearerToken"], token);
        assert!(
            parsed.get("providers").is_some(),
            "existing auth.json keys must be preserved"
        );
    }

    // ── Permissions ──

    #[cfg(unix)]
    #[test]
    fn write_token_sets_mode_0o600() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, path) = temp_token_path();
        load_or_create_bearer_token(&path).expect("create");
        let mode = std::fs::metadata(&path).expect("stat").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "auth.json must be 0o600, got {mode:o}");
    }

    // ── Rotation ──

    #[test]
    fn rotate_creates_different_token() {
        let (_dir, path) = temp_token_path();
        let first = load_or_create_bearer_token(&path).expect("create");
        let second = rotate_bearer_token(&path).expect("rotate");
        assert_ne!(first, second, "rotation must produce a different token");
    }

    #[test]
    fn rotate_persists_new_token_to_disk() {
        let (_dir, path) = temp_token_path();
        let _ = load_or_create_bearer_token(&path).expect("create");
        let rotated = rotate_bearer_token(&path).expect("rotate");
        let read_back = load_or_create_bearer_token(&path).expect("read");
        assert_eq!(
            read_back, rotated,
            "subsequent loads must see the rotated token"
        );
    }

    #[test]
    fn rotate_works_when_file_absent() {
        // First-time rotation (no prior file) is the same as create.
        let (_dir, path) = temp_token_path();
        let token = rotate_bearer_token(&path).expect("rotate from cold");
        assert_eq!(token.len(), ENCODED_TOKEN_LEN);
        assert!(path.exists());
    }

    #[test]
    fn concurrent_rotate_produces_one_consistent_token() {
        // Eight threads rotate the same path simultaneously. The mutex
        // serializes them; the file always parses cleanly; the final
        // token is whatever rotation won the race.
        let (_dir, path) = temp_token_path();
        let path = Arc::new(path);
        let mut handles = Vec::new();
        for _ in 0..8 {
            let p = Arc::clone(&path);
            handles.push(thread::spawn(move || {
                rotate_bearer_token(&p).expect("rotate")
            }));
        }
        let returned: Vec<String> = handles.into_iter().map(|h| h.join().unwrap()).collect();

        // Final file must parse and match one of the rotated tokens.
        let final_token = load_or_create_bearer_token(&path).expect("read final");
        assert!(
            returned.contains(&final_token),
            "final on-disk token must match one of the rotation results"
        );
    }

    #[test]
    fn atomic_write_no_partial_under_concurrent_readers() {
        // Mirrors `auth/storage.rs`'s `save_is_atomic_under_concurrent_readers`.
        // Reader thread spins on read_token while the writer thread rotates
        // 100 times; reader must never observe a torn file.
        let (_dir, path) = temp_token_path();
        let path = Arc::new(path);
        // Seed the file so the reader has something to read on iteration 0.
        let _ = load_or_create_bearer_token(&path).expect("seed");

        let stop = Arc::new(AtomicBool::new(false));
        let reader_path = Arc::clone(&path);
        let reader_stop = Arc::clone(&stop);
        let bad_reads = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let bad = Arc::clone(&bad_reads);
        let reader = thread::spawn(move || {
            while !reader_stop.load(Ordering::Relaxed) {
                match read_token(&reader_path) {
                    Ok(Some(t)) => {
                        if t.len() != ENCODED_TOKEN_LEN {
                            bad.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    Ok(None) => {
                        // The file should never disappear; absence here is bad.
                        bad.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(_) => {
                        bad.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        });

        for _ in 0..100 {
            let _ = rotate_bearer_token(&path).expect("rotate");
        }
        // Let the reader run a hair longer to catch any post-write tearing.
        thread::sleep(Duration::from_millis(20));
        stop.store(true, Ordering::Relaxed);
        reader.join().expect("reader join");

        assert_eq!(
            bad_reads.load(Ordering::Relaxed),
            0,
            "concurrent reader must never observe a torn or missing file"
        );
    }

    // ── Sentinel ──

    #[test]
    fn is_onboarded_false_when_marker_absent() {
        let (_dir, path) = temp_marker_path();
        assert!(!is_onboarded(&path));
    }

    #[test]
    fn is_onboarded_true_when_marker_present() {
        let (_dir, path) = temp_marker_path();
        mark_onboarded(&path).expect("mark");
        assert!(is_onboarded(&path));
    }

    #[test]
    fn mark_onboarded_creates_empty_file() {
        let (_dir, path) = temp_marker_path();
        mark_onboarded(&path).expect("mark");
        assert!(path.exists());
        let contents = std::fs::read(&path).expect("read");
        assert!(
            contents.is_empty(),
            "sentinel must be an empty file (existence is the only signal)"
        );
    }

    #[test]
    fn mark_onboarded_is_idempotent() {
        let (_dir, path) = temp_marker_path();
        mark_onboarded(&path).expect("first");
        mark_onboarded(&path).expect("second");
        assert!(is_onboarded(&path));
    }

    #[test]
    fn mark_onboarded_creates_parent_directory() {
        let dir = tempfile::tempdir().expect("tempdir");
        let nested = dir.path().join("nested/internal/run/.onboarded");
        assert!(!nested.parent().unwrap().exists());
        mark_onboarded(&nested).expect("mark with missing parent");
        assert!(nested.exists());
    }

    // ── Path helpers ──

    #[test]
    fn bearer_token_path_lives_under_profiles_dir() {
        let p = bearer_token_path();
        let s = p.to_string_lossy();
        assert!(s.ends_with("/auth.json"), "got: {s}");
        assert!(
            s.contains("/.tron/profiles/"),
            "must live under ~/.tron/profiles/, got: {s}"
        );
    }

    #[test]
    fn onboarded_marker_path_lives_under_internal_dir() {
        let p = onboarded_marker_path();
        let s = p.to_string_lossy();
        assert!(s.ends_with("/run/.onboarded"), "got: {s}");
        assert!(
            s.contains("/.tron/internal/run/"),
            "must live under ~/.tron/internal/run/, got: {s}"
        );
    }
}
