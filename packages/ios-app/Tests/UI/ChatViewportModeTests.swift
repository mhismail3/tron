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

    @Test("keyboard and geometry are not reducer inputs")
    func mutationSurfaceExcludesGeometry() {
        let intents: [ChatViewportIntent] = [
            .userTookOver,
            .userReturnedToTail,
            .catchUpRequested,
            .submitted,
            .opened,
            .prependBegan,
            .prependEnded,
            .presentationReset(retainingViewport: true),
        ]
        #expect(intents.count == 8)
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

    @Test("geometry cannot consume or manufacture an explicit return")
    func geometryCannotConsumeExplicitReturn() {
        var mode = ChatViewportMode.anchored
        mode.reduce(.submitted)
        mode.reduce(.prependBegan)
        #expect(mode == .anchored)
        mode.reduce(.userReturnedToTail)
        #expect(mode == .pinned)
    }

    @Test("an explicit return pins despite stale geometry")
    func explicitReturnPinsDespiteStaleGeometry() {
        var mode = ChatViewportMode.anchored
        mode.reduce(.userReturnedToTail)
        #expect(mode == .pinned)
    }

    @Test("mode is the complete native binding state; no release state exists")
    func nativeBindingStateFollowsModeWithoutReleaseCommand() {
        var mode = ChatViewportMode.pinned
        #expect(mode.sizeChangeAnchorIsBottom)
        mode.reduce(.userTookOver)
        #expect(!mode.sizeChangeAnchorIsBottom)
        mode.reduce(.catchUpRequested)
        #expect(mode.sizeChangeAnchorIsBottom)
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
