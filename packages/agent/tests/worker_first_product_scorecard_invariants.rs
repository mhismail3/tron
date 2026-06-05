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
        "Current score: **67/100**",
        "Status: **active; JARVIS-2, JARVIS-3, JARVIS-4, JARVIS-5, JARVIS-6, JARVIS-7, and JARVIS-8 passed; JARVIS-0 visual baseline, JARVIS-1 vocabulary/static gates, JARVIS-9 docs/examples, JARVIS-10 cleanup gates, and JARVIS-11 soak remain open**",
        "Evidence manifest: [`worker-first-product-evidence-manifest.md`](worker-first-product-evidence-manifest.md)",
        "| JARVIS-0 | Formalize scorecard and baseline | 5 | running |",
        "| JARVIS-1 | Primitive collapse | 8 | running |",
        "| JARVIS-2 | Default autonomy policy | 12 | passed_after_fix |",
        "| JARVIS-3 | Worker-first orchestration | 10 | passed_after_fix |",
        "| JARVIS-4 | Work snapshot API | 10 | passed_after_fix |",
        "| JARVIS-5 | iOS Work dashboard | 12 | passed_after_fix |",
        "| JARVIS-6 | Chat noise reduction | 8 | passed_after_fix |",
        "| JARVIS-7 | Worker/detail sheets | 8 | passed_after_fix |",
        "| JARVIS-8 | Guardrails and settings UX | 7 | passed_after_fix |",
        "| JARVIS-9 | Docs and examples | 6 | pending |",
        "| JARVIS-10 | Cleanup and static gates | 7 | pending |",
        "| JARVIS-11 | Soak, visual QA, and closeout | 7 | pending |",
        "Default autonomy means run-unless-blocked, not ask-first.",
        "Approval-required metadata becomes audited auto-decision records",
        "`agent::work_snapshot` contract/handler/projection",
        "model-visible context now renders `# Worker Guide`",
        "a real integration test fans out two session workers",
        "projects live subagent jobs as `workerType=agent` Worker cards",
        "Replaced top-level `NavigationMode.engine` with `NavigationMode.work`",
        "Fix during visual proof: wide section icons clipped on iPhone",
        "replaced reflective detail-card glass with solid readable surfaces",
        "Extended `agent::work_snapshot` workers with server-owned `trust` and `generatedControls`",
        "Agent settings expose Autonomy Mode with Independent/Testing prompt mode and plain Guardrails rows",
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
        manifest.contains("Current score: **67/100**")
            && manifest.contains("| JARVIS-0 | running |")
            && manifest.contains("| JARVIS-1 | running |")
            && manifest.contains("| JARVIS-2 | passed_after_fix |")
            && manifest.contains("| JARVIS-3 | passed_after_fix |")
            && manifest.contains("| JARVIS-4 | passed_after_fix |")
            && manifest.contains("| JARVIS-5 | passed_after_fix |")
            && manifest.contains("| JARVIS-6 | passed_after_fix |")
            && manifest.contains("| JARVIS-7 | passed_after_fix |")
            && manifest.contains("| JARVIS-8 | passed_after_fix |")
            && manifest.contains("| JARVIS-11 | pending |")
            && manifest.contains("Visual baseline screenshots remain open.")
            && manifest.contains("Baseline primary iOS source included `NavigationMode.engine`")
            && manifest.contains("Console views.")
            && manifest.contains("Fresh simulator test proof: 47 selected tests passed"),
        "worker-first evidence manifest must track the active baseline and open visual proof"
    );
    assert!(
        manifest.contains("Green proof: 27 selected simulator tests passed")
            && manifest.contains("capability-invocation-detail-work-render.png")
            && manifest.contains("solid detail-surface guard")
            && manifest.contains("reflected text bleed inside the Work card")
            && scorecard.contains("Closed for chat/action detail projection."),
        "worker-first evidence manifest must record the JARVIS-6 chat/action checkpoint without closing worker details"
    );
    assert!(
        manifest.contains("Fresh simulator proof after copy/render changes: 17 XCTest cases plus 36 Swift Testing cases passed")
            && manifest.contains("agent-settings-autonomy-render.png")
            && manifest.contains("The in-thread tool registry exposed no simulator tap/computer-use control.")
            && scorecard.contains("Closed for settings UX. JARVIS-11 owns final paired-server soak/action proof."),
        "worker-first evidence manifest must track the active baseline and open visual proof"
    );
    assert!(
        manifest.contains("Top-level iOS Work mode reads `agent::work_snapshot`")
            && manifest.contains("work-dashboard-iphone-render.png")
            && manifest.contains("work-dashboard-ipad-render.png")
            && manifest.contains("Target simulator UDID: `7BDA4AF9-1C40-47E3-A925-0F88C191F263`")
            && manifest.contains("The primary iOS route is now `NavigationMode.work`, not")
            && manifest.contains("raw catalog/plugin/implementation/binding count grids")
            && scorecard.contains("JARVIS-7 later closed worker detail state-matrix screenshots"),
        "worker-first evidence manifest must record the JARVIS-5/JARVIS-8 checkpoint without closing later rows"
    );
    assert!(
        manifest.contains("Worker detail sheets consume server-owned trust/generated controls")
            && manifest.contains("WorkGeneratedControlDTO")
            && manifest.contains("WorkDashboardState.guardrailsForWorker")
            && manifest.contains("worker-detail-running-render.png")
            && manifest.contains("worker-detail-success-render.png")
            && manifest.contains("worker-detail-failure-render.png")
            && manifest.contains("worker-detail-blocked-render.png")
            && manifest.contains("JARVIS-7 is closed for worker/detail sheets.")
            && scorecard.contains("Closed for worker/detail sheets."),
        "worker-first evidence manifest must record the JARVIS-7 worker detail checkpoint"
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
