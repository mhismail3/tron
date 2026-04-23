import Foundation
import Testing
@testable import TronMobile

/// Tests for the re-pair plumbing on `ConnectionSettingsPage`. SwiftUI views
/// don't lend themselves to direct rendering tests in this codebase — these
/// instead pin the **stable contracts** the View depends on:
///
///   1. `AddOrEditServerSheet.Mode: Identifiable` so `.sheet(item:)` can
///      distinguish add-vs-edit and rebuild the sheet when the bound preset
///      changes (e.g. tapping Re-pair on row A then row B).
///   2. The `rePairCurrentServer` notification name is stable so the chat
///      pill can post against the same string the settings page observes.
///
/// Both are deceptively easy to break in a refactor — the View compiles
/// either way, but the runtime behaviour silently regresses.
@Suite("ConnectionSettingsPage re-pair plumbing")
struct ConnectionSettingsPageRePairTests {

    private func preset(
        id: String = "p1",
        host: String = "100.64.0.1",
        port: Int = 9847
    ) -> ConnectionPreset {
        ConnectionPreset(id: id, label: "L", host: host, port: port)
    }

    // MARK: - Mode.id

    @Test("AddOrEditServerSheet.Mode.add has stable id 'add'")
    func addModeIdentity() {
        #expect(AddOrEditServerSheet.Mode.add.id == "add")
    }

    @Test("AddOrEditServerSheet.Mode.edit identity uses the preset id")
    func editModeIdentityIncludesPresetId() {
        let mode = AddOrEditServerSheet.Mode.edit(preset(id: "abc-123"))
        #expect(mode.id == "edit:abc-123")
    }

    @Test("Different presets produce different edit-mode ids so .sheet(item:) rebuilds")
    func editModeIdentityIsPerPreset() {
        let a = AddOrEditServerSheet.Mode.edit(preset(id: "first"))
        let b = AddOrEditServerSheet.Mode.edit(preset(id: "second"))
        #expect(a.id != b.id)
    }

    @Test("Add and Edit modes never share an id")
    func addAndEditDoNotCollide() {
        let editIds = (0..<10).map { i in
            AddOrEditServerSheet.Mode.edit(preset(id: "p-\(i)")).id
        }
        for id in editIds {
            #expect(id != "add", "edit id collided with add: \(id)")
        }
    }

    // MARK: - Notification name

    @Test("rePairCurrentServer notification name is the documented string")
    func rePairNotificationName() {
        // Hard-coded literal — if a refactor changes the underlying string,
        // the chat pill (which posts) and settings page (which observes)
        // would silently stop matching. This is the canary.
        #expect(Notification.Name.rePairCurrentServer.rawValue == "rePairCurrentServer")
    }

    @Test("Posting rePairCurrentServer reaches local observers synchronously")
    func notificationDispatchesToObservers() async {
        // The chat pill's onRePair posts on the main runloop; the settings
        // page observes via .onReceive. NotificationCenter delivers
        // synchronously by default (.default). Sanity-check the contract.
        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .rePairCurrentServer,
            object: nil,
            queue: nil
        ) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: .rePairCurrentServer, object: nil)
        NotificationCenter.default.post(name: .rePairCurrentServer, object: nil)

        #expect(received == 2)
    }
}
