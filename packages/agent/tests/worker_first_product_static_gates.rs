//! Static ownership gates for the worker-first product migration.

use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("packages/agent should have a repo root grandparent")
        .to_path_buf()
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_root().join(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

#[test]
fn ios_audit_surface_is_audit_details_and_work_path_stays_server_owned() {
    let root = repo_root();

    for retired in [
        "packages/ios-app/Sources/Views/EngineConsole",
        "packages/ios-app/Sources/ViewModels/State/EngineConsoleState.swift",
        "packages/ios-app/Sources/ViewModels/State/EngineConsoleCreatedByAgentProjection.swift",
        "packages/ios-app/Sources/ViewModels/State/EngineConsoleModuleProjection.swift",
        "packages/ios-app/Sources/Services/Storage/EngineConsoleCache.swift",
    ] {
        assert!(
            !root.join(retired).exists(),
            "audit-only iOS surface must not keep old primary Engine Console ownership path: {retired}"
        );
    }

    for required in [
        "packages/ios-app/Sources/Views/AuditDetails/AuditDetailsView.swift",
        "packages/ios-app/Sources/Views/AuditDetails/AuditDetailsComponents.swift",
        "packages/ios-app/Sources/Views/AuditDetails/AuditDetailsSection.swift",
        "packages/ios-app/Sources/ViewModels/State/AuditDetailsState.swift",
        "packages/ios-app/Sources/ViewModels/State/AuditDetailsWorkerArtifactProjection.swift",
        "packages/ios-app/Sources/ViewModels/State/AuditDetailsWorkerPackProjection.swift",
        "packages/ios-app/Sources/Services/Storage/AuditDetailsCache.swift",
    ] {
        assert!(
            root.join(required).is_file(),
            "audit-only iOS surface must use Audit Details ownership path: {required}"
        );
    }

    let work_dashboard =
        read_repo_file("packages/ios-app/Sources/Views/Work/WorkDashboardView.swift");
    let work_state =
        read_repo_file("packages/ios-app/Sources/ViewModels/State/WorkDashboardState.swift");
    let agent_client =
        read_repo_file("packages/ios-app/Sources/Services/Network/Clients/AgentClient.swift");
    let default_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");

    assert!(
        work_dashboard.contains("AuditDetailsView(")
            && !work_dashboard.contains("EngineConsole")
            && work_dashboard.contains("Audit Details"),
        "Work dashboard must open Audit Details without naming Engine Console"
    );

    for forbidden_visible_term in ["Substrate", "Primer", "Bindings", "Engine Console"] {
        assert!(
            !work_dashboard.contains(forbidden_visible_term),
            "Work dashboard primary UI must not expose audit vocabulary `{forbidden_visible_term}`"
        );
    }

    for (label, content) in [
        ("WorkDashboardView", work_dashboard.as_str()),
        ("WorkDashboardState", work_state.as_str()),
        ("AgentClient", agent_client.as_str()),
    ] {
        for forbidden in [
            "CapabilityClient",
            "ApprovalClient",
            "capability::registry_snapshot",
            "capability::policy_get",
            "capabilities.primer",
            "approval::resolve",
            "EngineConsole",
        ] {
            assert!(
                !content.contains(forbidden),
                "{label} must stay a thin Work snapshot client and not own audit/policy/approval truth via `{forbidden}`"
            );
        }
    }

    let ios_sources = files_with_extensions(&root.join("packages/ios-app/Sources"), &["swift"]);
    for path in ios_sources {
        let rel = path
            .strip_prefix(&root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        for retired in ["EngineConsole", "Engine Console", "Created by Agent"] {
            assert!(
                !content.contains(retired),
                "{rel} must not expose retired primary product wording `{retired}`"
            );
        }
    }

    assert!(
        default_profile.contains("approvalPromptMode = \"disabled\""),
        "default profile must keep approval prompts disabled"
    );
}

fn files_with_extensions(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_files_with_extensions(root, extensions, &mut files);
    files
}

fn visit_files_with_extensions(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", root.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|error| panic!("failed to read entry in {}: {error}", root.display()))
            .path();
        if path.is_dir() {
            visit_files_with_extensions(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext))
        {
            files.push(path);
        }
    }
}
