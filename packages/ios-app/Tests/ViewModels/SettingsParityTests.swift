import XCTest
@testable import TronMobile

/// Settings parity meta-test.
///
/// CLAUDE.md codifies a rule that every server setting decoded into
/// `ServerSettings` must have a 1-to-1 control in the iOS settings UI.
/// There is no Swift reflection path from the `ServerSettings` struct
/// because its fields are read from JSON via `decodeIfPresent`, not
/// codable synthesis. Instead, this test walks `SettingsState`'s
/// runtime fields via `Mirror` — every field on the observable
/// projection is expected to either be part of the user-editable
/// surface (covered by `KNOWN_UI_FIELDS`) or on `WAIVER` with an
/// explanation for why it doesn't need a UI control.
///
/// A new server field added to the iOS decode path will eventually
/// land on `SettingsState`, at which point this test fires until the
/// maintainer updates either the UI list or the waiver.
@MainActor
final class SettingsParityTests: XCTestCase {

    /// Fields that are wired to a UI control somewhere under
    /// `Views/Settings/Pages/`. Adding a field here requires a real
    /// UI control — the test only asserts the field is accounted for,
    /// not that it's actually displayed, but the intent is explicit.
    private let KNOWN_UI_FIELDS: Set<String> = [
        // General
        "defaultModel",
        "quickSessionWorkspace",
        // Context compaction
        "preserveRecentCount",
        "triggerTokenThreshold",
        // Rules
        "rulesDiscoverStandaloneFiles",
        // Message queue
        "queueDrainMode",
        // Hooks
        "hooksLlmModel",
        "builtinHooks",
        "hooksErrorPolicy",
        // Skills
        "skillsCompactionPolicy",
        "skillsShowIndex",
        // Memory
        "autoRetainInterval",
        "retainModel",
        // Git safety
        "gitProtectedBranches",
        // Prompt library
        "promptHistoryEnabled",
        "promptHistoryMaxEntries",
        "promptHistoryMaxAgeDays",
        "promptHistoryAutoPrune",
        // plugin source
        "mcpSchemaRefreshTtlMs",
        // Engine diagnostics
        "observabilityLogLevel",
        "observabilityPayloadCapture",
        "observabilityVerboseRetentionDays",
        "observabilityMaxInlinePayloadBytes",
        "storageRetentionEnabled",
        "storageMaxDatabaseMb",
        // Transcription (ConnectionSettingsPage.swift)
        "transcriptionEnabled",
        // Update checks (ConnectionSettingsPage.swift)
        "updateEnabled",
        "updateChannel",
        "updateFrequency",
        "updateAction",
    ]

    /// Explicit waivers — fields that exist on SettingsState but are
    /// NOT user-editable settings. Adding a waiver requires a reason.
    private let WAIVER: [String: String] = [
        "availableModels": "cached model list from models.list engine protocol — not a setting",
        "isLoaded": "UI loading flag — not persisted",
        "isLoadingModels": "UI loading flag — not persisted",
        "loadError": "transient error state — surfaced inline in the UI, not a setting",
        "lastLoadedSettings": "rollback snapshot for failed sparse updates — not a setting",
        "isolationMode": "session default still comes from server settings; new-session flow exposes the per-session isolation choice",
        "gitTargetBranch": "source-control action sheets choose targets per action or let the server auto-detect the repository default",
        "gitSessionBranchPolicy": "merge/finalize action sheets expose branch cleanup per action instead of a global settings sheet toggle",
        "gitMergeStrategy": "merge/finalize action sheets expose strategy per action instead of a global settings sheet toggle",
        "gitAutoSetUpstream": "push action sheet exposes upstream behavior per push; the server default remains decoded for action-sheet initialization",
        "gitCrashRecoveryAbortTimeoutMs": "operational timeout kept server-side; not exposed as an end-user settings control",
        "gitOpTimeoutNetworkMs": "operational timeout kept server-side; not exposed as an end-user settings control",
        "gitOpTimeoutLocalMs": "operational timeout kept server-side; not exposed as an end-user settings control",
        "gitSubagentConflictResolutionEnabled": "conflict resolution is offered in the source-control flow; the global offer gate is intentionally not exposed in settings",
    ]

    /// Normalize a Mirror child label into the user-level field name.
    ///
    /// `@Observable` rewrites stored properties into `_name` backing
    /// fields plus a synthesized `_$observationRegistrar`. We care
    /// about the logical names only.
    private func normalize(_ label: String) -> String? {
        // Strip the leading `_` that @Observable inserts on stored
        // properties.
        let stripped = label.hasPrefix("_") ? String(label.dropFirst()) : label
        // After stripping, anything starting with `$` is compiler
        // plumbing (observation registrar) and not a user field.
        if stripped.hasPrefix("$") { return nil }
        return stripped
    }

    func testEverySettingsStateFieldIsWiredOrWaived() {
        let state = SettingsState()
        let mirror = Mirror(reflecting: state)

        var orphans: [String] = []
        for child in mirror.children {
            guard let raw = child.label, let name = normalize(raw) else { continue }
            if KNOWN_UI_FIELDS.contains(name) { continue }
            if WAIVER[name] != nil { continue }
            orphans.append(name)
        }

        XCTAssertTrue(
            orphans.isEmpty,
            """
            SettingsState fields without a UI control or waiver: \(orphans).
            Either add a UI control in Views/Settings/Pages/ and register
            the field in KNOWN_UI_FIELDS, or add an entry to WAIVER with
            a justification.
            """
        )
    }

    /// Detect waivers that were added but then the field got renamed
    /// or removed — stale waivers silently reduce coverage.
    func testNoStaleWaiversForRemovedFields() {
        let state = SettingsState()
        let actualFields = Set(
            Mirror(reflecting: state).children.compactMap { $0.label.flatMap(normalize) }
        )

        var stale: [String] = []
        for waived in WAIVER.keys where !actualFields.contains(waived) {
            stale.append(waived)
        }

        XCTAssertTrue(
            stale.isEmpty,
            "Waiver entries for fields that no longer exist: \(stale). Remove from WAIVER."
        )
    }

    /// Same check on the KNOWN_UI_FIELDS list — a registered field
    /// that's been removed from SettingsState becomes a lie.
    func testNoStaleUIRegistrationsForRemovedFields() {
        let state = SettingsState()
        let actualFields = Set(
            Mirror(reflecting: state).children.compactMap { $0.label.flatMap(normalize) }
        )

        var stale: [String] = []
        for registered in KNOWN_UI_FIELDS where !actualFields.contains(registered) {
            stale.append(registered)
        }

        XCTAssertTrue(
            stale.isEmpty,
            "KNOWN_UI_FIELDS entries that no longer exist on SettingsState: \(stale). Remove from the set."
        )
    }
}
