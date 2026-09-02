import Foundation
import Testing
@testable import TronMobile

struct DisplayPresentationTests {
    @Test("display wire metadata is bounded and modes downgrade deterministically")
    func displayWireAdmission() throws {
        let data = Data(#"""
        {
          "schema":"tron.display.v1",
          "displayId":"display-1",
          "revision":1,
          "title":"Preview",
          "altText":"A preview image.",
          "kind":"image",
          "presentation":{"requestedSurface":"floating","inlineTapAction":"sheet"},
          "eligibleSurfaces":["sheet","inline","floating"],
          "fallbackText":"A preview image.",
          "artifact":{
            "id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b",
            "name":"preview.png",
            "mimeType":"image/png",
            "size":128,
            "kind":"image"
          }
        }
        """#.utf8)
        let display = try JSONDecoder.gateway.decode(DisplayProjection.self, from: data)
        #expect(DisplayPresentationPolicy.effectiveSurface(for: display) == .floating)
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .webpage) == [.sheet])

        let webpage = DisplayProjection(
            displayId: "web",
            title: "Web",
            altText: "A webpage.",
            kind: .webpage,
            presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet),
            eligibleSurfaces: [.sheet],
            fallbackText: "A webpage.",
            remoteURL: "https://example.com"
        )
        #expect(DisplayPresentationPolicy.effectiveSurface(for: webpage) == .sheet)
    }

    @Test("malformed display descriptors fail closed")
    func malformedWire() {
        let unsafe = Data(#"""
        {
          "schema":"tron.display.v1",
          "displayId":"display-1",
          "revision":1,
          "title":"Web",
          "altText":"Web",
          "kind":"webpage",
          "presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},
          "eligibleSurfaces":["sheet"],
          "fallbackText":"Web",
          "remoteURL":"http://example.com"
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(DisplayProjection.self, from: unsafe)
        }
        for remote in [
            "https://127.0.0.1/page",
            "https://localhost./page",
            "https://[::1]/page",
            "https://[fc00::1]/page",
            "https://example.com/page?token=secret",
            "https://example.com/page#credential",
        ] {
            #expect(!DisplayRemoteURLPolicy.admits(remote))
        }
        #expect(DisplayRemoteURLPolicy.admits("https://example.com/page"))
    }

    @Test("floating completion tracking suppresses history and reconnect replay")
    func floatingCompletionTracking() throws {
        let historical = imageDisplay(id: "historical")
        let live = imageDisplay(id: "live")
        var tracker = DisplayFloatingCompletionTracker()
        let initial = tracker.transition(to: [historical])
        #expect(initial == nil)
        let candidate = tracker.transition(to: [historical, live])
        let transition = try #require(candidate)
        #expect(transition.previous == [historical])
        #expect(transition.current == [historical, live])
        let reset = tracker.transition(to: nil)
        #expect(reset == nil)
        let reconnect = tracker.transition(to: [historical, live])
        #expect(reconnect == nil)
    }

    @Test("new floating completions are single-owner and defer behind covering presentation")
    func floatingAdmission() {
        let display = imageDisplay(id: "new")
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [], current: [display], sceneActive: true,
            presentationReady: true, allowsPresentation: true,
            hasFloatingDisplay: false, consumedRevisionIDs: []
        ) == .present(display))
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [], current: [display], sceneActive: true,
            presentationReady: true, allowsPresentation: false,
            hasFloatingDisplay: false, consumedRevisionIDs: []
        ) == .deferred(display))
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [display], current: [display], sceneActive: true,
            presentationReady: true, allowsPresentation: true,
            hasFloatingDisplay: false, consumedRevisionIDs: []
        ) == .none)
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [], current: [display], sceneActive: false,
            presentationReady: true, allowsPresentation: true,
            hasFloatingDisplay: false, consumedRevisionIDs: []
        ) == .none)
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [], current: [display], sceneActive: true,
            presentationReady: true, allowsPresentation: true,
            hasFloatingDisplay: true, consumedRevisionIDs: []
        ) == .none)
    }

    @Test("inline disclosure settles interrupted transitions and rejects stale completions")
    func inlineDisclosureState() throws {
        var state = DisplayInlineDisclosureState()
        #expect(state.rendersInlineContainer)
        #expect(state.inlineOpacity == 1)
        #expect(state.permitsInteraction)

        let collapse = try #require(state.proposed(.collapse))
        state.begin(collapse)
        #expect(state.rendersInlineContainer)
        #expect(state.inlineOpacity == 0)
        #expect(state.pillOpacity == 1)
        #expect(!state.permitsInteraction)
        #expect(state.proposed(.collapse) == nil)
        #expect(state.proposed(.expand) == nil)

        state.settleTransientPhase()
        #expect(state.isCollapsed)
        #expect(state.pillOpacity == 1)
        #expect(state.permitsInteraction)
        let staleCompletionAccepted = state.complete(collapse)
        #expect(!staleCompletionAccepted)

        let expand = try #require(state.proposed(.expand))
        state.begin(expand)
        #expect(!state.rendersInlineContainer)
        #expect(state.pillOpacity == 1)
        #expect(!state.permitsInteraction)
        let expansionCompleted = state.complete(expand)
        #expect(expansionCompleted)
        #expect(state.rendersInlineContainer)
        #expect(state.inlineOpacity == 1)
    }

    @Test("inline display viewport stays bounded without forcing short content tall")
    func adaptiveInlineViewport() {
        #expect(DisplayInlineLayoutPolicy.maximumViewportHeight == 320)
        #expect(DisplayInlineLayoutPolicy.cornerRadius == 22)
        #expect(DisplayInlineLayoutPolicy.controlDiameter == 34)
        #expect(DisplayInlineLayoutPolicy.controlTouchTarget >= 44)
        #expect(DisplayInlineLayoutPolicy.contentTopPadding == 4)
        #expect(DisplayInlineLayoutPolicy.openingViewportHeight(for: .markdown) == 180)
        #expect(DisplayInlineLayoutPolicy.openingViewportHeight(for: .image) == 220)
        #expect(DisplayInlineLayoutPolicy.imageChipScale == 1.7)
        #expect(DisplayInlineLayoutPolicy.imageChipSide == 108.8)
    }

    @Test("large media suppresses automatic embedding but admits explicit floating activation")
    func largeMediaDowngrade() {
        let large = DisplayPresentationPolicy.maximumEmbeddedMediaBytes + 1
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .video, artifactSize: large) == [.sheet])
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .audio, artifactSize: large) == [.sheet])
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .video, artifactSize: large - 1)
            == [.sheet, .inline, .floating])
        let video = DisplayProjection(
            displayId: "large-video",
            title: "Video",
            altText: "A large video.",
            kind: .video,
            presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet),
            eligibleSurfaces: [.sheet],
            fallbackText: "A large video.",
            artifact: .init(
                id: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b",
                name: "video.mp4",
                mimeType: "video/mp4",
                size: large,
                kind: .video
            )
        )
        #expect(DisplayPresentationPolicy.effectiveSurface(for: video) == .sheet)
        #expect(DisplayPresentationPolicy.activationSurface(for: video) == .floating)
        #expect(DisplayFloatingAdmissionPolicy.admission(
            previous: [], current: [video], sceneActive: true,
            presentationReady: true, allowsPresentation: true,
            hasFloatingDisplay: false, consumedRevisionIDs: []
        ) == .none)
    }

    @Test("floating panel spans toolbar-to-composer space and snaps horizontally")
    func floatingPanelGeometry() {
        let size = DisplayFloatingLayoutPolicy.panelSize(in: CGSize(width: 390, height: 800))
        let safe = DisplayFloatingLayoutPolicy.safeCenterRect(
            container: CGSize(width: 390, height: 800),
            safeTop: 20,
            safeBottom: 10,
            bottomExclusion: 90,
            panelSize: size
        )
        #expect(safe.minY == 20 + size.height / 2 + 8)
        #expect(safe.maxY == 800 - 10 - 90 - size.height / 2 - 8)
        let snapped = DisplayFloatingLayoutPolicy.snappedToNearestHorizontalEdge(
            CGPoint(x: safe.midX - 1, y: safe.midY),
            in: safe
        )
        #expect(snapped.x == safe.minX)
        #expect(snapped.y == safe.midY)
        #expect(DisplayFloatingLayoutPolicy.controlTouchTarget >= 44)
    }

    @Test("running display invocation preserves requested pill destination")
    func runningInvocation() {
        let tool = ChatToolPresentation(
            id: "call", title: "Display", toolName: "display", subtitle: "Running",
            request: .object([
                "presentation": .object(["surface": .string("inline")])
            ]),
            response: nil, content: "", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: nil,
            lastProgressAt: nil, progressSequence: nil
        )
        #expect(tool.descriptor.requestedDisplaySurface == .inline)
        #expect(tool.descriptor.display == nil)
    }

    @Test("durable display media routes carry exact session authorization")
    func mediaRoute() {
        let id = "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b"
        #expect(GatewayClient.mediaPath(id: id, sessionID: "session-1")
            == "/v1/sessions/session-1/display-artifacts/\(id)")
        #expect(GatewayClient.mediaPath(id: "not-a-uuid", sessionID: "session-1") == nil)
    }

    private func imageDisplay(id: String) -> DisplayProjection {
        DisplayProjection(
            displayId: id,
            title: "Preview",
            altText: "Preview image.",
            kind: .image,
            presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet),
            eligibleSurfaces: [.sheet, .inline, .floating],
            fallbackText: "Preview image.",
            artifact: .init(
                id: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b",
                name: "preview.png",
                mimeType: "image/png",
                size: 128,
                kind: .image
            )
        )
    }
}
