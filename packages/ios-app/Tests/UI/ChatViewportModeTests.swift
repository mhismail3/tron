import Testing
@testable import TronMobile

@Suite("Chat viewport mode")
struct ChatViewportModeTests {
    @Test("only explicit reader intents change mode")
    func explicitIntentReduction() {
        var mode = ChatViewportMode.pinned
        mode.reduce(.submitted)
        mode.reduce(.prependBegan)
        mode.reduce(.prependEnded)
        #expect(mode == .pinned)

        mode.reduce(.userTookOver)
        #expect(mode == .anchored)
        mode.reduce(.submitted)
        #expect(mode == .anchored)
        mode.reduce(.userReturnedToTail)
        #expect(mode == .pinned)
    }

    @Test("retained presentation keeps reader authority")
    func retainedPresentation() {
        var mode = ChatViewportMode.anchored
        mode.reduce(.presentationReset(retainingViewport: true))
        #expect(mode == .anchored)
        mode.reduce(.presentationReset(retainingViewport: false))
        #expect(mode == .pinned)
    }

    @Test("catch-up and opening pin while submission preserves detachment")
    func systemIntents() {
        var mode = ChatViewportMode.anchored
        mode.reduce(.submitted)
        #expect(mode == .anchored)
        mode.reduce(.catchUpRequested)
        #expect(mode == .pinned)
        mode.reduce(.userTookOver)
        mode.reduce(.opened)
        #expect(mode == .pinned)
    }

    @Test("direct takeover wins over submission and prepend intents")
    func directTakeoverCancelsPendingAutomaticWork() {
        var mode = ChatViewportMode.pinned
        mode.reduce(.submitted)
        mode.reduce(.prependBegan)
        mode.reduce(.userTookOver)
        mode.reduce(.prependEnded)
        #expect(mode == .anchored)
    }
}
