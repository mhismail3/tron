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
        "Current score: **32/100**",
        "Status: **active; JARVIS-2, JARVIS-3, and JARVIS-4 passed; JARVIS-1 vocabulary/static gates, JARVIS-0 visual baseline, and JARVIS-8 guardrail UX remain open**",
        "Evidence manifest: [`worker-first-product-evidence-manifest.md`](worker-first-product-evidence-manifest.md)",
        "| JARVIS-0 | Formalize scorecard and baseline | 5 | running |",
        "| JARVIS-1 | Primitive collapse | 8 | running |",
        "| JARVIS-2 | Default autonomy policy | 12 | passed_after_fix |",
        "| JARVIS-3 | Worker-first orchestration | 10 | passed_after_fix |",
        "| JARVIS-4 | Work snapshot API | 10 | passed_after_fix |",
        "| JARVIS-5 | iOS Work dashboard | 12 | pending |",
        "| JARVIS-6 | Chat noise reduction | 8 | pending |",
        "| JARVIS-7 | Worker/detail sheets | 8 | pending |",
        "| JARVIS-8 | Guardrails and settings UX | 7 | running |",
        "| JARVIS-9 | Docs and examples | 6 | pending |",
        "| JARVIS-10 | Cleanup and static gates | 7 | pending |",
        "| JARVIS-11 | Soak, visual QA, and closeout | 7 | pending |",
        "Default autonomy means run-unless-blocked, not ask-first.",
        "Approval-required metadata becomes audited auto-decision records",
        "`agent::work_snapshot` contract/handler/projection",
        "model-visible context now renders `# Worker Guide`",
        "a real integration test fans out two session workers",
        "projects live subagent jobs as `workerType=agent` Worker cards",
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
        manifest.contains("Current score: **32/100**")
            && manifest.contains("| JARVIS-0 | running |")
            && manifest.contains("| JARVIS-1 | running |")
            && manifest.contains("| JARVIS-2 | passed_after_fix |")
            && manifest.contains("| JARVIS-3 | passed_after_fix |")
            && manifest.contains("| JARVIS-4 | passed_after_fix |")
            && manifest.contains("| JARVIS-8 | running |")
            && manifest.contains("| JARVIS-11 | pending |")
            && manifest.contains("Visual baseline screenshots remain open.")
            && manifest
                .contains("Current primary iOS source still includes `NavigationMode.engine`")
            && manifest.contains("Console views.")
            && manifest.contains("Fresh simulator test proof: 47 selected tests passed"),
        "worker-first evidence manifest must track the active baseline and open visual proof"
    );
    assert!(
        manifest.contains("Fresh simulator proof after copy/render changes: 17 XCTest cases plus 36 Swift Testing cases passed")
            && manifest.contains("agent-settings-autonomy-render.png")
            && manifest.contains("The in-thread tool registry exposed no simulator tap/computer-use control.")
            && scorecard.contains("Remaining: add plain Guardrails UX and capture paired-server action checks before awarding points."),
        "worker-first evidence manifest must track the active baseline and open visual proof"
    );
    assert!(
        manifest.contains("worker_first_orchestration_fans_out_session_workers_without_approvals")
            && manifest.contains("work_snapshot -- --nocapture")
            && manifest.contains("JARVIS-3 is closed for server orchestration/projection.")
            && scorecard.contains("Closed for server orchestration/projection."),
        "worker-first evidence manifest must record the JARVIS-3 checkpoint without overclaiming other rows"
    );

    assert!(
        readme.contains("packages/agent/docs/worker-first-product-scorecard.md")
            && readme.contains("active worker-first product scorecard")
            && readme.contains("packages/agent/docs/worker-first-product-evidence-manifest.md"),
        "README living-doc map must link the active worker-first scorecard and evidence manifest"
    );
}
