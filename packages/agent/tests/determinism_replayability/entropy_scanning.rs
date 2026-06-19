use super::support::*;
use std::path::{Path, PathBuf};

#[test]
fn drc_entropy_inventory_names_replay_critical_patterns() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for required in [
        "utc_now",
        "system_time_now",
        "instant_now",
        "uuid_now_v7",
        "rand_random",
    ] {
        assert!(
            inventory.contains(required),
            "DRC entropy inventory must include {required}"
        );
    }
}

#[test]
fn replay_entropy_guard_module_is_wired_to_closeout_target() {
    let source = read_source_tree_text();
    assert!(
        source.contains("determinism_replayability_invariants"),
        "local/GitHub closeout wiring must run the DRC invariant target"
    );
}

#[test]
fn replay_critical_entropy_is_allow_listed() {
    let patterns = [
        EntropyPattern {
            label: "wall-clock UTC",
            needles: &["Utc::now", "chrono::Utc::now"],
            allowed_paths: &[
                "packages/agent/src/app/",
                "packages/agent/src/domains/agent/",
                "packages/agent/src/domains/approval/",
                "packages/agent/src/domains/auth/",
                "packages/agent/src/domains/capability/operations/",
                "packages/agent/src/domains/memory/",
                "packages/agent/src/domains/model/",
                "packages/agent/src/domains/session/event_store/envelope/",
                "packages/agent/src/domains/session/event_store/identity.rs",
                "packages/agent/src/domains/session/event_store/reconstruction/tests/",
                "packages/agent/src/domains/session/event_store/sqlite/contention.rs",
                "packages/agent/src/domains/session/event_store/sqlite/repositories/session/",
                "packages/agent/src/domains/session/event_store/sqlite/repositories/workspace.rs",
                "packages/agent/src/domains/session/lifecycle/",
                "packages/agent/src/domains/session/query/",
                "packages/agent/src/domains/settings/",
                "packages/agent/src/domains/system/",
                "packages/agent/src/engine/",
                "packages/agent/src/platform/",
                "packages/agent/src/shared/",
                "packages/agent/src/transport/",
            ],
        },
        EntropyPattern {
            label: "system wall-clock",
            needles: &["SystemTime::now"],
            allowed_paths: &["packages/agent/src/domains/model/providers/"],
        },
        EntropyPattern {
            label: "duration clock",
            needles: &["Instant::now", "std::time::Instant::now"],
            allowed_paths: &[
                "packages/agent/src/app/",
                "packages/agent/src/domains/agent/",
                "packages/agent/src/domains/auth/oauth/",
                "packages/agent/src/domains/capability/operations/",
                "packages/agent/src/domains/model/",
                "packages/agent/src/domains/settings/",
                "packages/agent/src/domains/session/event_store/reconstruction/tests/",
                "packages/agent/src/domains/session/event_store/sqlite/connection.rs",
                "packages/agent/src/domains/session/event_store/sqlite/contention.rs",
                "packages/agent/src/domains/transcription/",
                "packages/agent/src/platform/",
                "packages/agent/src/shared/server/",
            ],
        },
        EntropyPattern {
            label: "uuidv7",
            needles: &["Uuid::now_v7", "uuid::Uuid::now_v7"],
            allowed_paths: &[
                "packages/agent/src/app/bootstrap/server.rs",
                "packages/agent/src/domains/agent/loop/orchestrator/agent_runner.rs",
                "packages/agent/src/domains/agent/prompt/",
                "packages/agent/src/domains/auth/oauth/",
                "packages/agent/src/domains/capability/operations/trace.rs",
                "packages/agent/src/domains/session/event_store/identity.rs",
                "packages/agent/src/domains/session/event_store/reconstruction/tests/",
                "packages/agent/src/domains/session/event_store/sqlite/repositories/workspace.rs",
                "packages/agent/src/domains/transcription/",
                "packages/agent/src/engine/",
                "packages/agent/src/shared/foundation/ids.rs",
                "packages/agent/src/shared/observability/",
                "packages/agent/src/shared/storage/",
                "packages/agent/src/transport/engine/socket/",
            ],
        },
        EntropyPattern {
            label: "rng",
            needles: &["rand::random", "rand::rng"],
            allowed_paths: &[
                "packages/agent/src/app/lifecycle/onboarding/",
                "packages/agent/src/domains/auth/credentials/pkce.rs",
                "packages/agent/src/domains/session/event_store/sqlite/contention.rs",
            ],
        },
        EntropyPattern {
            label: "timestamp-only ordering",
            needles: &["ORDER BY timestamp"],
            allowed_paths: &[
                "packages/agent/src/domains/session/event_store/sqlite/repositories/event/type_queries.rs",
                "packages/agent/src/domains/session/event_store/sqlite/repositories/trace.rs",
            ],
        },
    ];

    let mut violations = Vec::new();
    for file in rust_source_files(&repo_path("packages/agent/src")) {
        let rel = relative_repo_path(&file);
        let text = std::fs::read_to_string(&file)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", file.display()));
        for (line_index, line) in text.lines().enumerate() {
            for pattern in &patterns {
                if pattern.needles.iter().any(|needle| line.contains(needle))
                    && !pattern.allows(&rel)
                {
                    violations.push(format!(
                        "{}:{}: {} outside replay entropy allow-list: {}",
                        rel,
                        line_index + 1,
                        pattern.label,
                        line.trim()
                    ));
                }
            }
        }
    }

    assert!(
        violations.is_empty(),
        "DRC-2 replay entropy allow-list violations:\n{}",
        violations.join("\n")
    );
}

#[test]
fn deterministic_constructor_seams_are_present() {
    let source = read_source_tree_text();
    for required in [
        "pub struct EventIdentity",
        "pub struct SessionCreationIdentity",
        "pub struct SessionForkIdentity",
        "create_session_with_identity",
        "fork_with_identity",
        "append_with_identity",
        "from_result_at",
    ] {
        assert!(
            source.contains(required),
            "DRC-3 deterministic constructor seam missing: {required}"
        );
    }
}

struct EntropyPattern {
    label: &'static str,
    needles: &'static [&'static str],
    allowed_paths: &'static [&'static str],
}

impl EntropyPattern {
    fn allows(&self, path: &str) -> bool {
        self.allowed_paths
            .iter()
            .any(|allowed| path.contains(allowed))
    }
}

fn rust_source_files(root: &Path) -> Vec<PathBuf> {
    fn visit(path: &Path, files: &mut Vec<PathBuf>) {
        if path.is_file() {
            if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
                files.push(path.to_path_buf());
            }
            return;
        }
        let entries = std::fs::read_dir(path)
            .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", path.display()));
        for entry in entries {
            visit(
                &entry.expect("directory entry should be readable").path(),
                files,
            );
        }
    }

    let mut files = Vec::new();
    visit(root, &mut files);
    files
}

fn relative_repo_path(path: &Path) -> String {
    path.strip_prefix(repo_root())
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}
