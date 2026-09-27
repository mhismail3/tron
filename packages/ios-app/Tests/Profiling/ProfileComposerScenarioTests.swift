import Foundation
import SwiftUI
import XCTest
@testable import TronMobile

/// Typing in the mounted chat composer: each keystroke goes through
/// `AppModel`'s composer entry point into the production
/// `ComposerDraftCoordinator`, whose 200 ms debounce persists the draft into
/// the real `ComposerDraftStore` on a temporary root. Four other drafts hold
/// image attachments, as they would after a user staged photos in other chats.
/// Keyboard and text-input system work is not part of this scenario.
@MainActor
final class ProfileComposerScenarioTests: XCTestCase {
    func testComposerTyping() throws {
        try profileScenario("composer-typing", defaultWindow: .seconds(10)) { window in
            try await ProfileComposerRun.make(window: window)
        }
    }
}

@MainActor
final class ProfileComposerRun: ProfileScenarioRun {
    /// One character every 110 ms within a word, then a 400 ms pause: longer
    /// than the 200 ms persistence debounce, so every word is saved.
    static let keystrokeInterval = Duration.milliseconds(110)
    static let wordPause = Duration.milliseconds(400)
    static let otherDrafts = 4
    static let attachmentsPerDraft = 2

    private let chat: ProfileChatRun
    private let store: ComposerDraftStore
    private let keystrokes: [(offset: Duration, text: String)]
    private var typed = ""

    private init(chat: ProfileChatRun, store: ComposerDraftStore, keystrokes: [(Duration, String)]) {
        self.chat = chat
        self.store = store
        self.keystrokes = keystrokes
    }

    static func make(window: Duration) async throws -> ProfileComposerRun {
        let history = ProfileTranscript.history(seed: 7_401, items: 60)
        let snapshot = try ProfileTranscript.snapshot(seed: 7_401, items: history)
        var created: ComposerDraftStore?
        let chat = try await ProfileChatRun.make(snapshot: snapshot, frames: []) { root in
            let store = ComposerDraftStore(root: root)
            created = store
            return store
        }
        guard let store = created else {
            await chat.teardown()
            throw ProfileScenarioError.notReady("the draft store was not created")
        }
        do {
            let images = try (0..<attachmentsPerDraft).map { index in
                try SessionScenarioBuilder(seed: 7_450 + index).generatedImageFixture(
                    format: .jpeg, pixelWidth: 1_024, pixelHeight: 768, orientation: .up
                ).encodedData
            }
            for draft in 0..<otherDrafts {
                await store.save(.init(
                    text: "Draft \(draft) waiting with photos",
                    attachments: images.enumerated().map { index, data in
                        .init(name: "photo-\(draft)-\(index).jpg", mimeType: "image/jpeg", data: data)
                    }
                ), for: ComposerDraftScope(profileID: chat.fixture.profile.id, sessionID: "profile-draft-\(draft)"))
            }
        } catch {
            await chat.teardown()
            throw error
        }
        ProfileScenarioLedger.shared.add("keystrokes", 0)
        return ProfileComposerRun(chat: chat, store: store, keystrokes: schedule(window: window))
    }

    private static func schedule(window: Duration) -> [(Duration, String)] {
        var words = ProfileTranscript.Words(seed: 7_402)
        var text = ""
        var offset = Duration.milliseconds(50)
        var keystrokes: [(Duration, String)] = []
        // Stop early enough that the last word's debounced save lands inside
        // the window.
        while true {
            let word = words.sentence(1).dropLast().lowercased() + " "
            let end = offset + keystrokeInterval * (word.count - 1)
            guard end + wordPause < window else { break }
            for character in word {
                text.append(character)
                keystrokes.append((offset, text))
                offset += keystrokeInterval
            }
            offset += wordPause - keystrokeInterval
        }
        return keystrokes
    }

    func ready() async throws {
        try await chat.ready()
        guard chat.fixture.model.setHostedComposerText("", sessionID: chat.snapshot.sessionId) else {
            throw ProfileScenarioError.notReady("the mounted chat has no composer draft scope")
        }
    }

    func workload(window: Duration) async throws {
        let start = ContinuousClock.now
        let model = chat.fixture.model
        let sessionID = chat.snapshot.sessionId
        for (offset, text) in keystrokes {
            try await profileSleep(until: offset, from: start)
            guard model.setHostedComposerText(text, sessionID: sessionID) else {
                throw ProfileScenarioError.workloadDiverged("the composer scope retired during typing")
            }
            ProfileScenarioLedger.shared.add("keystrokes")
            typed = text
        }
        try await profileSleep(until: window, from: start)
    }

    /// The last word must have been persisted by the debounced save.
    func verify() async throws {
        let scope = ComposerDraftScope(profileID: chat.fixture.profile.id, sessionID: chat.snapshot.sessionId)
        let manifest = await store.hostedPath(for: scope).appending(path: "manifest.json")
        struct Manifest: Decodable { let text: String }
        func readSaved() -> String? { try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).text }
        let typed = typed
        try? await profileWaitUntil("the debounced draft save", timeout: .seconds(10)) { readSaved() == typed }
        let saved = readSaved()
        guard saved == typed else {
            throw ProfileScenarioError.workloadDiverged("the draft store holds \(saved.map { "\($0.count) characters" } ?? "no draft"), expected \(typed.count)")
        }
    }

    var surface: UIView? { chat.surface }

    func teardown() async {
        await chat.teardown()
    }
}
