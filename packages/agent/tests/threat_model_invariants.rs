//! Meta-test: every `[T]` (trusted-local) finding from the audit plan
//! carries an `INVARIANT:` marker in source that names the trust
//! boundary and its hardening path.
//!
//! Background: the Tron audit plan produced a set of findings tagged
//! `[T]` — accepted trade-offs under the trusted-local threat model
//! (the only callers are the user's own devices over Tailscale). Each
//! `[T]` trade-off is documented in source with an `INVARIANT:` block
//! naming:
//!   1. the current behavior,
//!   2. why it's safe under trusted-local,
//!   3. the concrete hardening path if the model changes.
//!
//! This test enforces the presence of those markers. If a future edit
//! silently strips the documentation, the marker vanishes, and this
//! test fails before the change can ship.
//!
//! To register a new `[T]` trade-off: add its (path, keyword) entry
//! to `TRUST_BOUNDARY_SITES` and commit the source-side INVARIANT
//! alongside. To remove one: only valid if the trade-off itself has
//! been hardened out of existence (e.g. real rate limiting replaces
//! the L7 documentation).

use std::path::{Path, PathBuf};

/// Sites that must document a trusted-local trust boundary.
///
/// Format: `(relative_path, required_substring_case_insensitive)`.
/// The test asserts the file contains both the literal string
/// `"INVARIANT"` and the required substring (lowercased comparison).
const TRUST_BOUNDARY_SITES: &[(&str, &str)] = &[
    // C1 — filesystem handlers accept arbitrary paths
    ("src/server/rpc/filesystem_service.rs", "trusted-local"),
    // C2 — server binds 0.0.0.0 by default
    ("src/main.rs", "trusted-local"),
    // M1 — NotFound messages echo caller-supplied IDs
    ("src/server/rpc/errors.rs", "trusted-local"),
    // M4 — BroadcastManager trusts client-claimed session_id
    ("src/server/websocket/broadcast.rs", "trusted-local"),
    // L7 — no per-client RPC rate limiting
    ("src/server/rpc/mod.rs", "trusted-local"),
    // L8 — client-supplied bundleId trusted at register time
    ("src/server/rpc/handlers/device.rs", "trusted-local"),
    // L14 — `is_path_within` is lexical, no symlink resolution
    ("src/runtime/guardrails/rules/path.rs", "trusted-local"),
];

/// Sites outside the Rust crate (e.g. shell scripts) — keyed on the
/// repo root rather than `CARGO_MANIFEST_DIR`. Resolved separately.
const TRUST_BOUNDARY_REPO_SITES: &[(&str, &str)] = &[
    // L3 — launchd plist is user-writable
    ("scripts/tron", "trusted-local"),
];

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Walk up from `crate_root` until we hit a directory that contains a
/// top-level `scripts/` sibling — that's the workspace/repo root.
fn repo_root() -> PathBuf {
    let mut cur = crate_root();
    for _ in 0..5 {
        if cur.join("scripts").join("tron").is_file() {
            return cur;
        }
        if !cur.pop() {
            break;
        }
    }
    panic!(
        "could not locate repo root from {:?}; scripts/tron not found walking up",
        crate_root()
    );
}

fn assert_site(root: &Path, relative: &str, keyword: &str) {
    let path = root.join(relative);
    let content =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
    assert!(
        content.contains("INVARIANT"),
        "{relative} must contain an INVARIANT marker (trusted-local [T] finding)"
    );
    assert!(
        content.to_lowercase().contains(keyword),
        "{relative} must name `{keyword}` somewhere in its INVARIANT block"
    );
}

#[test]
fn every_trusted_local_finding_has_invariant_marker() {
    let crate_root = crate_root();
    for (rel, keyword) in TRUST_BOUNDARY_SITES {
        assert_site(&crate_root, rel, keyword);
    }

    let repo_root = repo_root();
    for (rel, keyword) in TRUST_BOUNDARY_REPO_SITES {
        assert_site(&repo_root, rel, keyword);
    }
}

/// Regression: the registered sites must all actually exist. A typo
/// in `TRUST_BOUNDARY_SITES` would otherwise only surface the first
/// time the specific file is read.
#[test]
fn every_registered_site_exists() {
    let crate_root = crate_root();
    for (rel, _) in TRUST_BOUNDARY_SITES {
        let path = crate_root.join(rel);
        assert!(
            path.is_file(),
            "registered site {rel} does not exist at {path:?}"
        );
    }
    let repo_root = repo_root();
    for (rel, _) in TRUST_BOUNDARY_REPO_SITES {
        let path = repo_root.join(rel);
        assert!(
            path.is_file(),
            "registered repo site {rel} does not exist at {path:?}"
        );
    }
}

#[test]
fn installed_pre_commit_hook_enforces_rustfmt_and_personal_info_guard() {
    let hook_installer = repo_root().join("scripts").join("install-hooks.sh");
    let content = std::fs::read_to_string(&hook_installer)
        .unwrap_or_else(|e| panic!("failed to read {hook_installer:?}: {e}"));

    assert!(
        content.contains("cargo fmt --all -- --check"),
        "pre-commit hook must block Rust formatting drift"
    );
    assert!(
        content.contains("personal-info-guard.sh\" --staged"),
        "pre-commit hook must keep the staged personal-info guard"
    );
}
