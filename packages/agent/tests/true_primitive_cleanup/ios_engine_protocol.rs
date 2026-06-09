use super::support::*;

#[test]
fn ios_engine_protocol_roots_are_split_and_cache_mode_explicit() {
    for (path, limit) in [
        (
            "packages/ios-app/Sources/UI/Onboarding/Steps/SetupSteps.swift",
            575,
        ),
        (
            "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
            575,
        ),
        (
            "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
            575,
        ),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-7 Swift file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/ios-app/Sources/UI/Onboarding/Steps/SetupStepComponents.swift",
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleTypes.swift",
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView+RenderingHelpers.swift",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-7 expected split owner missing: {path}"
        );
    }

    let setup = read_repo_file("packages/ios-app/Sources/UI/Onboarding/Steps/SetupSteps.swift");
    assert!(
        !setup.contains("struct SetupActionButton")
            && !setup.contains("struct CredentialEntryCard"),
        "SetupSteps.swift must not own reusable setup controls"
    );

    let diagnostics = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
    );
    assert!(
        !diagnostics.contains("struct DiagnosticsBundle:")
            && !diagnostics.contains("enum DiagnosticsEventSanitizer"),
        "DiagnosticsBundleBuilder.swift must not own bundle DTOs or sanitization helpers"
    );

    let runtime = read_repo_file(
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
    );
    assert!(
        !runtime.contains("func arrayStrings(") && !runtime.contains("func rowPreview("),
        "GeneratedRuntimeSurfaceView.swift must keep pure rendering helpers in its extension owner"
    );

    let event_database =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift");
    assert!(
        event_database.contains("storageMode = .temporaryCache")
            && event_database.contains("server substrate remains authoritative"),
        "temporary event cache mode must remain explicit and projection-only"
    );
}
