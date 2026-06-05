//! Static guard for the active worker-first product scorecard.

use std::path::PathBuf;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn repo_root() -> PathBuf {
    let mut current = crate_root();
    for _ in 0..5 {
        if current.join("scripts").join("tron").is_file() {
            return current;
        }
        if !current.pop() {
            break;
        }
    }
    panic!(
        "could not locate repo root from {:?}; scripts/tron not found walking up",
        crate_root()
    );
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_root().join(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

#[test]
fn worker_first_product_scorecard_stays_formalized_without_overclaiming() {
    let scorecard = read_repo_file("packages/agent/docs/worker-first-product-scorecard.md");
    let manifest = read_repo_file("packages/agent/docs/worker-first-product-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Worker-First Tron Product Scorecard",
        "Current score: **0/100**",
        "Status: **active; JARVIS-0 baseline formalization in progress**",
        "Evidence manifest: [`worker-first-product-evidence-manifest.md`](worker-first-product-evidence-manifest.md)",
        "| JARVIS-0 | Formalize scorecard and baseline | 5 | running |",
        "| JARVIS-1 | Primitive collapse | 8 | pending |",
        "| JARVIS-2 | Default autonomy policy | 12 | pending |",
        "| JARVIS-3 | Worker-first orchestration | 10 | pending |",
        "| JARVIS-4 | Work snapshot API | 10 | pending |",
        "| JARVIS-5 | iOS Work dashboard | 12 | pending |",
        "| JARVIS-6 | Chat noise reduction | 8 | pending |",
        "| JARVIS-7 | Worker/detail sheets | 8 | pending |",
        "| JARVIS-8 | Guardrails and settings UX | 7 | pending |",
        "| JARVIS-9 | Docs and examples | 6 | pending |",
        "| JARVIS-10 | Cleanup and static gates | 7 | pending |",
        "| JARVIS-11 | Soak, visual QA, and closeout | 7 | pending |",
        "Default autonomy means run-unless-blocked, not ask-first.",
        "Remote package discovery, push, merge, release, deploy, and production",
        "Visual baseline screenshots are still open and block JARVIS-0 points.",
    ] {
        assert!(
            scorecard.contains(required),
            "worker-first scorecard missing required text: {required}"
        );
    }

    for stale_claim in [
        "Current score: **100/100**",
        "Status: **completed**",
        "| JARVIS-11 | Soak, visual QA, and closeout | 7 | passed",
        "No worker-first scorecard rows remain open.",
    ] {
        assert!(
            !scorecard.contains(stale_claim),
            "worker-first scorecard must not overclaim completion: {stale_claim}"
        );
    }

    assert!(
        manifest.contains("Current score: **0/100**")
            && manifest.contains("| JARVIS-0 | running |")
            && manifest.contains("| JARVIS-11 | pending |")
            && manifest.contains("Visual baseline screenshots remain open.")
            && manifest
                .contains("Current primary iOS source still includes `NavigationMode.engine`")
            && manifest.contains("Console views."),
        "worker-first evidence manifest must track the active baseline and open visual proof"
    );

    assert!(
        readme.contains("packages/agent/docs/worker-first-product-scorecard.md")
            && readme.contains("active worker-first product scorecard")
            && readme.contains("packages/agent/docs/worker-first-product-evidence-manifest.md"),
        "README living-doc map must link the active worker-first scorecard and evidence manifest"
    );
}
