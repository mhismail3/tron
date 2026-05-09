//! Engine transport bearer-token authentication middleware.
//!
//! Gates `/engine` and `/engine/workers` upgrades behind a bearer token stored as `bearerToken`
//! in `~/.tron/profiles/auth.json`. The token is created lazily by
//! [`crate::app::onboarding::load_or_create_bearer_token`] at server
//! startup; the upgrade handlers ask this module to verify the
//! `Authorization: Bearer <token>` header before starting an engine protocol
//! session.
//!
//! ## Why a small cache
//!
//! The token rarely changes (only on `tron auth rotate`), but every
//! incoming WS upgrade needs to compare against it. Reading the file on
//! every request is wasteful, so [`BearerTokenStore`] keeps an in-memory
//! copy and refreshes it whenever the file's mtime changes. That makes
//! the steady-state cost ~one `stat(2)` per upgrade, which is negligible
//! compared to the rest of the upgrade dance.
//!
//! The mtime-based refresh also means an external rotation (e.g. someone
//! ran `tron auth rotate` from another shell while the server is up) is
//! picked up on the next upgrade attempt without any signal-handling.
//!
//! ## Constant-time comparison
//!
//! [`tokens_eq`] compares the candidate against the canonical token in
//! constant time. The token is a 43-character URL-safe base64 string, so
//! length differs only when the client is sending obvious garbage; we
//! still avoid early-exit on byte mismatch to defeat timing oracles.

#![deny(unsafe_code)]

#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::time::SystemTime;

use axum::http::{HeaderMap, StatusCode, header};
use parking_lot::Mutex;

use crate::app::onboarding::load_or_create_bearer_token;

/// In-memory cache of the bearer token loaded from disk.
///
/// The cache is invalidated by file mtime: each `current_token` call
/// stats the file and re-reads if mtime changed. The first lookup after
/// boot loads the file (creating it if absent — see
/// [`load_or_create_bearer_token`]). Subsequent lookups are O(1) plus a
/// stat.
///
/// Cloning the store is cheap (just clones the `PathBuf`); the mutex is
/// not shared across clones intentionally — every `Arc<BearerTokenStore>`
/// shares one cache, but multiple stores at different paths (tests) get
/// independent caches.
pub struct BearerTokenStore {
    path: PathBuf,
    cached: Mutex<Option<CachedToken>>,
}

#[derive(Clone)]
struct CachedToken {
    token: String,
    mtime: SystemTime,
}

impl BearerTokenStore {
    /// Build a store backed by `path`. The file is not read until the
    /// first call to [`Self::current_token`] or [`Self::verify`].
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            cached: Mutex::new(None),
        }
    }

    /// Return the current bearer token, refreshing the cache if the
    /// underlying file's mtime has changed.
    ///
    /// Returns `None` if the token file is absent **and** could not be
    /// created (e.g. permission denied on the parent directory). The
    /// "absent → 401" path lets the Mac wizard treat a freshly-installed
    /// server that hasn't yet generated its token as "still starting up"
    /// rather than a fatal misconfig.
    pub fn current_token(&self) -> Option<String> {
        let on_disk_mtime = std::fs::metadata(&self.path)
            .and_then(|m| m.modified())
            .ok();

        // Cache hit: file exists and mtime matches the cached entry.
        {
            let guard = self.cached.lock();
            if let (Some(cached), Some(disk)) = (guard.as_ref(), on_disk_mtime)
                && cached.mtime == disk
            {
                return Some(cached.token.clone());
            }
        }

        // Cache miss: load (or create) the token and stamp the cache
        // with the now-current mtime. If the read fails entirely (e.g.
        // a parent directory we can't write), surface `None` and let
        // the caller return 401.
        let token = load_or_create_bearer_token(&self.path).ok()?;
        let mtime = std::fs::metadata(&self.path)
            .and_then(|m| m.modified())
            .ok()?;
        let mut guard = self.cached.lock();
        *guard = Some(CachedToken {
            token: token.clone(),
            mtime,
        });
        Some(token)
    }

    /// Constant-time comparison of `presented` against the current
    /// canonical token. Returns `false` if the file cannot be loaded.
    pub fn verify(&self, presented: &str) -> bool {
        match self.current_token() {
            Some(canonical) => tokens_eq(presented.as_bytes(), canonical.as_bytes()),
            None => false,
        }
    }

    /// Path the store is reading from (test only).
    #[cfg(test)]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Verify the `Authorization` header against `store`.
///
/// Requires a header of the form `Authorization: Bearer <token>` where
/// `<token>` matches the file on disk. Any deviation returns
/// `401 UNAUTHORIZED`.
///
/// The 401 response intentionally carries no body — the iOS client
/// distinguishes 401-vs-network-error from the upgrade response status
/// alone and routes into its `ConnectionState::unauthorized` UI.
pub fn verify_bearer_header(
    headers: &HeaderMap,
    store: &BearerTokenStore,
) -> Result<(), StatusCode> {
    let Some(value) = headers.get(header::AUTHORIZATION) else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let Ok(value_str) = value.to_str() else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let Some(presented) = value_str.strip_prefix("Bearer ") else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    // Disallow any form that doesn't end with the token directly; e.g.
    // `Bearer  abc` (double space) is rejected. Trim only trailing
    // whitespace, which some HTTP clients append, but reject leading.
    let presented = presented.trim_end();
    if presented.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    if store.verify(presented) {
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

/// Constant-time byte-slice equality. Equivalent to `subtle::ConstantTimeEq`
/// but pulls no extra dependency. Behaviour:
///   - Always traverses the full length of the longer slice (to avoid a
///     length-shortcut oracle).
///   - Combines per-byte XOR into a single accumulator that the compiler
///     cannot legally short-circuit.
fn tokens_eq(a: &[u8], b: &[u8]) -> bool {
    let len = a.len().max(b.len());
    let mut diff: u8 = (a.len() ^ b.len()) as u8;
    for i in 0..len {
        let x = *a.get(i).unwrap_or(&0);
        let y = *b.get(i).unwrap_or(&0);
        diff |= x ^ y;
    }
    diff == 0
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::Duration;

    fn temp_store() -> (tempfile::TempDir, BearerTokenStore) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("auth.json");
        let store = BearerTokenStore::new(path);
        (dir, store)
    }

    fn header_with_bearer(value: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(value).expect("header value"),
        );
        h
    }

    // ── Constant-time compare ─────────────────────────────────────────

    #[test]
    fn tokens_eq_accepts_matching_strings() {
        assert!(tokens_eq(b"hello", b"hello"));
    }

    #[test]
    fn tokens_eq_rejects_different_strings() {
        assert!(!tokens_eq(b"hello", b"world"));
    }

    #[test]
    fn tokens_eq_rejects_different_lengths() {
        assert!(!tokens_eq(b"hello", b"hello!"));
        assert!(!tokens_eq(b"hello!", b"hello"));
    }

    #[test]
    fn tokens_eq_rejects_empty_vs_nonempty() {
        assert!(!tokens_eq(b"", b"x"));
        assert!(!tokens_eq(b"x", b""));
    }

    #[test]
    fn tokens_eq_accepts_two_empty() {
        // Defensive — never used in practice, but a regression here
        // would imply the accumulator is wrong on the zero path.
        assert!(tokens_eq(b"", b""));
    }

    // ── BearerTokenStore basics ───────────────────────────────────────

    #[test]
    fn store_creates_token_on_first_lookup() {
        let (_dir, store) = temp_store();
        assert!(!store.path().exists());
        let token = store.current_token().expect("create on first call");
        assert_eq!(token.len(), 43, "URL-safe base64 of 32 bytes");
        assert!(store.path().exists());
    }

    #[test]
    fn store_returns_same_token_across_repeat_calls() {
        let (_dir, store) = temp_store();
        let a = store.current_token().expect("first");
        let b = store.current_token().expect("second");
        assert_eq!(a, b);
    }

    #[test]
    fn store_reloads_when_file_mtime_changes() {
        // Simulates `tron auth rotate` running in another process and
        // changing the file out from under us. The cache must pick it
        // up on the next lookup.
        let (_dir, store) = temp_store();
        let original = store.current_token().expect("seed");

        // Sleep one filesystem-mtime tick before rewriting so the new
        // mtime is observably different. macOS APFS has 1 ns resolution
        // but some Linux filesystems have 1 s; the conservative wait
        // covers both.
        std::thread::sleep(std::time::Duration::from_millis(1100));

        let rotated = crate::app::onboarding::rotate_bearer_token(store.path()).expect("rotate");
        assert_ne!(rotated, original, "rotation must produce a new token");

        let observed = store.current_token().expect("reload");
        assert_eq!(observed, rotated, "store must observe rotation");
    }

    #[test]
    fn store_returns_none_when_path_unwritable() {
        // A path inside a non-existent, non-creatable directory yields
        // None rather than a panic. We use `/dev/null/auth.json`
        // because creating subdirectories of `/dev/null` always fails
        // with NotADirectory on Unix.
        let store = BearerTokenStore::new(PathBuf::from("/dev/null/auth.json"));
        assert!(store.current_token().is_none());
    }

    // ── verify_bearer_header ─────────────────────────────────────────

    #[test]
    fn mandatory_rejects_missing_header() {
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");
        let headers = HeaderMap::new();
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_rejects_non_bearer_scheme() {
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");
        let headers = header_with_bearer("Basic dXNlcjpwYXNz");
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_rejects_empty_bearer() {
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");
        let headers = header_with_bearer("Bearer ");
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_rejects_wrong_bearer() {
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");
        let headers = header_with_bearer("Bearer not-the-right-token");
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_rejects_bearer_with_leading_whitespace() {
        let (_dir, store) = temp_store();
        let token = store.current_token().expect("seed");
        // "Bearer  <token>" has a double space; the second space gets
        // included in `presented` after stripping "Bearer ", producing
        // " <token>". That doesn't match the canonical and must 401.
        let headers = header_with_bearer(&format!("Bearer  {token}"));
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_accepts_correct_bearer() {
        let (_dir, store) = temp_store();
        let token = store.current_token().expect("seed");
        let headers = header_with_bearer(&format!("Bearer {token}"));
        assert!(verify_bearer_header(&headers, &store).is_ok());
    }

    #[test]
    fn mandatory_tolerates_trailing_whitespace_in_bearer() {
        // Some HTTP clients append a trailing CR/LF or space; the
        // header was already validated by axum so we won't see CR/LF,
        // but we do trim trailing spaces because that's a common iOS
        // copy-paste artifact.
        let (_dir, store) = temp_store();
        let token = store.current_token().expect("seed");
        let headers = header_with_bearer(&format!("Bearer {token}   "));
        assert!(verify_bearer_header(&headers, &store).is_ok());
    }

    #[test]
    fn mandatory_rejects_when_token_file_unreachable() {
        // No file, unwritable parent. Even with a header present, 401 is
        // the right answer because there's no
        // canonical token to compare against. This is the
        // "server-not-initialized" path the Mac wizard polls past.
        let store = BearerTokenStore::new(PathBuf::from("/dev/null/auth.json"));
        let headers = header_with_bearer("Bearer some-value");
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_rejects_after_rotation_with_old_token() {
        let (_dir, store) = temp_store();
        let original = store.current_token().expect("seed");

        std::thread::sleep(std::time::Duration::from_millis(1100));
        let _ = crate::app::onboarding::rotate_bearer_token(store.path()).expect("rotate");

        // Same store; old token should now be rejected.
        let headers = header_with_bearer(&format!("Bearer {original}"));
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn mandatory_accepts_new_token_after_rotation() {
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");

        std::thread::sleep(std::time::Duration::from_millis(1100));
        let rotated = crate::app::onboarding::rotate_bearer_token(store.path()).expect("rotate");

        let headers = header_with_bearer(&format!("Bearer {rotated}"));
        assert!(verify_bearer_header(&headers, &store).is_ok());
    }

    #[test]
    fn mandatory_rejects_non_ascii_header() {
        // Token can never contain non-ASCII (URL-safe base64), so a
        // non-ASCII Authorization value is by definition wrong. This
        // also exercises the `to_str()` failure branch.
        let (_dir, store) = temp_store();
        let _ = store.current_token().expect("seed");
        let mut headers = HeaderMap::new();
        // Bytes for "Bearer \u{FFFD}" — invalid UTF-8 in HeaderValue
        let value = HeaderValue::from_bytes(b"Bearer \xFF\xFE").expect("non-ascii header");
        headers.insert(header::AUTHORIZATION, value);
        let err = verify_bearer_header(&headers, &store).unwrap_err();
        assert_eq!(err, StatusCode::UNAUTHORIZED);
    }

    // ── Concurrency ───────────────────────────────────────────────────

    #[test]
    fn concurrent_verification_under_rotation_never_panics() {
        // Stress: 4 reader threads spinning on `verify` while a writer
        // rotates 50 times. We don't assert outcomes (some reads land
        // before the swap, some after — both Ok and Err are valid) but
        // we DO assert no panics or torn cache.
        let (_dir, store) = temp_store();
        let store = Arc::new(store);
        let _ = store.current_token().expect("seed");

        let stop = Arc::new(AtomicBool::new(false));
        let mut handles = Vec::new();
        for _ in 0..4 {
            let s = Arc::clone(&store);
            let stop = Arc::clone(&stop);
            handles.push(thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    // Pull a token, build a header from it, verify.
                    if let Some(t) = s.current_token() {
                        let h = header_with_bearer(&format!("Bearer {t}"));
                        let _ = verify_bearer_header(&h, &s);
                    }
                }
            }));
        }

        for _ in 0..50 {
            std::thread::sleep(Duration::from_millis(5));
            let _ = crate::app::onboarding::rotate_bearer_token(store.path()).expect("rotate");
        }

        stop.store(true, Ordering::Relaxed);
        for h in handles {
            h.join().expect("reader thread");
        }
    }
}
