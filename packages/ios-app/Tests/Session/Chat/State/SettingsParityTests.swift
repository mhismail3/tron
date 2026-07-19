import XCTest
@testable import TronMobile

/// Settings parity meta-test.
///
/// AGENTS.md codifies a rule that every server setting decoded into
/// `ServerSettings` must have a 1-to-1 control in the iOS settings UI.
/// There is no Swift reflection path from the `ServerSettings` struct
/// because it uses a custom strict decoder rather than Codable synthesis.
/// The first bridge test reflects the decoded DTO and repository snapshot so a
/// newly decoded field cannot be silently dropped before it reaches state. The
/// remaining tests walk `SettingsState`'s runtime fields via `Mirror` — every field on the observable
/// projection is expected to either be represented in the settings
/// surface (covered by `KNOWN_UI_FIELDS`) or on `WAIVER` with an
/// explanation for why it doesn't need a UI control.
///
/// A new server field added to the iOS decode path must be projected into the
/// snapshot and state before the UI list or a waiver can be updated.
@MainActor
final class SettingsParityTests: XCTestCase {

    /// Fields that are wired to a UI control somewhere under
    /// `Sources/UI/Settings/Pages/`. Adding a field here requires a real
    /// UI control or read-only row — the test only asserts the field is accounted for,
    /// not that it's actually displayed, but the intent is explicit.
    private let KNOWN_UI_FIELDS: Set<String> = [
        // General
        "defaultModel",
        "quickSessionWorkspace",
        "tailscaleIp",
        // Context compaction
        "preserveRecentCount",
        "triggerTokenThreshold",
        // Engine transcription policy
        "transcriptionEnabled",
    ]

    /// Explicit waivers — fields that exist on SettingsState but are
    /// NOT user-editable settings. Adding a waiver requires a reason.
    private let WAIVER: [String: String] = [
        "isLoaded": "UI loading flag — not persisted",
        "loadError": "transient error state — surfaced inline in the UI, not a setting",
        "lastLoadedSettings": "rollback snapshot for failed sparse updates — not a setting",
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

    func testEveryDecodedSettingsFieldProjectsIntoSnapshot() throws {
        let json = #"{"server":{"defaultWorkspace":"/parity-workspace","tailscaleIp":"100.64.0.7","transcription":{"enabled":true}},"context":{"compactor":{"preserveRecentCount":7,"triggerTokenThreshold":0.55}}}"#
        let settings = try JSONDecoder().decode(
            ServerSettings.self,
            from: try ServerSettingsFixture.data(json)
        )

        XCTAssertEqual(
            Set(Mirror(reflecting: settings).children.compactMap(\.label)),
            Set(["defaultModel", "defaultWorkspace", "tailscaleIp", "compaction", "transcriptionEnabled"])
        )
        XCTAssertEqual(
            Set(Mirror(reflecting: settings.compaction).children.compactMap(\.label)),
            Set(["preserveRecentCount", "triggerTokenThreshold"])
        )

        let snapshot = ServerSettingsSnapshot(settings)
        XCTAssertEqual(snapshot, ServerSettingsSnapshot(
            defaultModel: "claude-sonnet-4-6",
            defaultWorkspace: "/parity-workspace",
            tailscaleIp: "100.64.0.7",
            compactionPreserveRecentCount: 7,
            compactionTriggerTokenThreshold: 0.55,
            transcriptionEnabled: true
        ))
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
            Either add a UI control in Sources/UI/Settings/Pages/ and register
            the field in KNOWN_UI_FIELDS, or add an entry to WAIVER with
            a justification.
            """
        )
    }

    /// Detect waiver entries that no longer match SettingsState fields.
    func testNoStaleWaiversForUnknownFields() {
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
            "Waiver entries for fields that no longer exist: \(stale). Update WAIVER."
        )
    }

    /// Same check on the KNOWN_UI_FIELDS list.
    func testNoStaleUIRegistrationsForUnknownFields() {
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
