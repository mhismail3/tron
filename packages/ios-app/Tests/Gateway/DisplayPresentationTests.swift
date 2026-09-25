import Foundation
import SwiftUI
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

    @Test("browser live displays remain opaque and are sheet/floating only")
    func browserLiveDisplay() throws {
        let data = Data(#"""
        {
          "schema":"tron.display.v1", "displayId":"live-1", "revision":1,
          "title":"Browser", "altText":"Live browser viewport", "kind":"browser_live",
          "presentation":{"requestedSurface":"floating","inlineTapAction":"sheet"},
          "eligibleSurfaces":["sheet","floating"], "fallbackText":"Unavailable",
          "liveView":{"schema":"tron.browser-live-view.v1","viewId":"view-1","generation":"runtime-1:browser-1","title":"Browser view","fallbackText":"Unavailable"}
        }
        """#.utf8)
        let display = try JSONDecoder.gateway.decode(DisplayProjection.self, from: data)
        #expect(display.liveView?.viewId == "view-1")
        #expect(DisplayPresentationPolicy.effectiveSurface(for: display) == .floating)
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .browserLive) == [.sheet, .floating])

        // Keep the image's valid surface list so this specifically detects the
        // wrong-kind/live-source defect rather than failing an unrelated guard.
        var wrongKind = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        wrongKind["kind"] = "image"
        wrongKind["eligibleSurfaces"] = ["sheet", "inline", "floating"]
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(DisplayProjection.self, from: JSONSerialization.data(withJSONObject: wrongKind))
        }
        var dualSource = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dualSource["remoteURL"] = "https://example.com"
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(DisplayProjection.self, from: JSONSerialization.data(withJSONObject: dualSource))
        }
    }

    @Test("native descriptors require their own schema and producer-scoped presentation identity")
    func nativeLiveDisplay() throws {
        let browser = browserDisplay(id: "same-call")
        var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder.gateway.encode(browser)) as? [String: Any])
        wire["kind"] = "native_live"
        // Same fields and eligibility do not make the two schemas aliases.
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(DisplayProjection.self, from: JSONSerialization.data(withJSONObject: wire))
        }
        var descriptor = try #require(wire["liveView"] as? [String: Any])
        descriptor["schema"] = "tron.native-live-view.v1"
        wire["liveView"] = descriptor
        let native = try JSONDecoder.gateway.decode(DisplayProjection.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(native.liveView?.viewId == browser.liveView?.viewId)
        #expect(native.presentationIdentity == "native:view:runtime:browser")
        #expect(browser.presentationIdentity == "browser:view:runtime:browser")
        #expect(native.presentationIdentity != browser.presentationIdentity)
        #expect(DisplayRoute(sessionID: "session", display: native).id != DisplayRoute(sessionID: "session", display: browser).id)
        #expect(DisplayPresentationPolicy.eligibleSurfaces(for: .nativeLive) == [.sheet, .floating])
        #expect(DisplayPresentationPolicy.activationSurface(for: native) == .floating)
        #expect(ToolDisplayActivation.command(for: toolDescriptor(name: "display", display: native), sessionID: "session")
            == .showFloating(DisplayRoute(sessionID: "session", display: native)))
        #expect(DisplayPresentationPolicy.invocationSurface(toolName: "display", request: .object([
            "source": .object(["kind": .string("native_live")])
        ])) == .floating)
        #expect(DisplayFloatingAdmissionPolicy.admission(previous: [browser], current: [browser, native], sceneActive: true,
            presentationReady: true, allowsPresentation: true, hasFloatingDisplay: false,
            consumedRevisionIDs: [browser.presentationIdentity]) == .present(native))
        var tracker = DisplayFloatingCompletionTracker()
        #expect(tracker.transition(to: [native]) == nil)
        #expect(tracker.transition(to: nil) == nil)
        #expect(tracker.transition(to: [native]) == nil) // history/reconnect installs do not start viewing

        let surface = PresentationSurfaceToken(id: "surface", generation: UUID())
        let oldSource = LiveFrameSource(sessionID: "session", profileID: "profile",
            presentationIdentity: browser.presentationIdentity, viewID: "view", generation: "runtime:browser",
            surface: surface, producerID: UUID(), activityGeneration: 1)
        #expect(!DisplayFloatingLayoutPolicy.matchesLiveSource(oldSource,
            route: DisplayRoute(sessionID: "session", display: native), profileID: "profile", surface: surface))
        wire["kind"] = "browser_live"
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(DisplayProjection.self, from: JSONSerialization.data(withJSONObject: wire))
        }
    }

    @Test("browser tool actions share floating identity, sticky dismissal, and manual reopening")
    @MainActor
    func browserToolActivation() throws {
        let first = browserDisplay(id: "action-1")
        let later = browserDisplay(id: "action-2")
        let presentation = ChatSessionPresentation(sessionID: "session")
        let tool = toolDescriptor(name: "agent_browser", display: first)
        let command = try #require(ToolDisplayActivation.command(for: tool, sessionID: "session"))
        #expect(command == .showFloating(DisplayRoute(sessionID: "session", display: first)))
        presentation.presentDisplay(command)
        let original = try #require(presentation.floatingDisplay)
        presentation.presentDisplay(.showFloating(DisplayRoute(sessionID: "session", display: later)))
        #expect(presentation.floatingDisplay == original)
        presentation.floatingDisplay = nil
        #expect(DisplayFloatingAdmissionPolicy.admission(previous: [], current: [later], sceneActive: true,
            presentationReady: true, allowsPresentation: true, hasFloatingDisplay: false,
            consumedRevisionIDs: [first.presentationIdentity]) == .none)
        presentation.presentDisplay(command)
        #expect(presentation.floatingDisplay == original)
        #expect(first.presentationIdentity == later.presentationIdentity)
        #expect(first.presentationIdentity != browserDisplay(id: "action-3", generation: "successor").presentationIdentity)
        #expect(ToolDisplayActivation.command(for: tool, sessionID: nil) == nil)
        let ordinary = toolDescriptor(name: "read")
        #expect(ToolDisplayActivation.command(for: ordinary, sessionID: "session") == nil)
    }

    @Test("grouped custom displays publish once after dismissal and reject stale owners")
    func groupedDisplayHandoff() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_832).openingTail(targetEncodedBytes: 4_096)
        let display = imageDisplay(id: "image")
        snapshot.transcript = [.message(.init(id: "result", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
            kind: .message, role: .toolResult, presentationId: "result", content: [], toolCallId: "call", display: display))]
        let source = snapshot
        let command = DisplayPresentationCommand.showSheet(DisplayRoute(sessionID: snapshot.sessionId, display: display))
        func staged() -> ToolDisplayHandoff {
            var handoff = ToolDisplayHandoff()
            handoff.stage(command, toolID: "call", runtime: snapshot.runtimeGeneration, installation: 1, profile: "profile")
            return handoff
        }
        var handoff = staged()
        #expect(handoff.consume(source: source, installation: 1, profile: "profile", active: true) == command)
        #expect(handoff.consume(source: source, installation: 1, profile: "profile", active: true) == nil)
        for (installation, profile, active) in [(2, "profile", true), (1, "next", true), (1, "profile", false)] {
            handoff = staged()
            #expect(handoff.consume(source: source, installation: installation, profile: profile, active: active) == nil)
            #expect(handoff.consume(source: source, installation: 1, profile: "profile", active: true) == nil)
        }
        for change in 0..<4 {
            handoff = staged()
            var replaced = snapshot
            if change == 0 { replaced.runtimeGeneration = "next" }
            if change == 1 { replaced.transcript = [] } // same-runtime canonical branch replacement
            if change == 2 { replaced.sessionId = "other-session" }
            if change == 3 {
                replaced.transcript = [.message(.init(id: "result", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                    kind: .message, role: .toolResult, presentationId: "result", content: [], toolCallId: "call",
                    display: imageDisplay(id: "image", revision: 2)))]
            }
            #expect(handoff.consume(source: replaced, installation: 1, profile: "profile", active: true) == nil)
        }
        // Unrelated canonical text/revisions do not invalidate the selected result.
        handoff = staged()
        snapshot.revision += 1
        #expect(handoff.consume(source: snapshot, installation: 1, profile: "profile", active: true) == command)
        handoff = staged()
        var paged = snapshot
        for index in 0..<512 {
            paged.transcript.append(.message(.init(id: "later-\(index)", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                kind: .message, role: .user, presentationId: "later-\(index)", content: [])))
        }
        #expect(handoff.consume(source: paged, installation: 1, profile: "profile", active: true) == command)
    }

    @Test("browser floating content keeps the 4:3 fallback within small safe bounds")
    func browserPanelAspect() {
        for container in [CGSize(width: 390, height: 800), CGSize(width: 320, height: 160)] {
            let size = DisplayFloatingLayoutPolicy.panelSize(in: container, live: true)
            #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.001)
            #expect(size.width <= container.width)
            #expect(size.height <= container.height)
        }
    }

    @Test("admitted browser frame ratios fit native bounds without shrinking controls")
    func browserPanelAdaptsToFrameRatio() {
        let container = CGSize(width: 390, height: 800)
        let portrait = DisplayFloatingLayoutPolicy.panelSize(
            in: container, live: true, liveAspectRatio: 9.0 / 16.0
        )
        let wide = DisplayFloatingLayoutPolicy.panelSize(
            in: container, live: true, liveAspectRatio: 32.0 / 9.0
        )
        let invalid = DisplayFloatingLayoutPolicy.panelSize(
            in: container, live: true, liveAspectRatio: .infinity
        )
        #expect(portrait.height > portrait.width)
        #expect(wide.width > wide.height)
        #expect(portrait.width >= DisplayFloatingLayoutPolicy.minimumUsableWidth)
        #expect(wide.height >= DisplayFloatingLayoutPolicy.minimumUsableHeight)
        #expect(invalid == DisplayFloatingLayoutPolicy.panelSize(in: container, live: true))
        for size in [portrait, wide] {
            #expect(size.width <= container.width - 16)
            #expect(size.height <= container.height - 16)
        }
        for ratio in [CGFloat(0.000001), 1_000_000] {
            let extreme = DisplayFloatingLayoutPolicy.panelSize(
                in: CGSize(width: 1024, height: 768), live: true, liveAspectRatio: ratio)
            #expect(extreme.width >= DisplayFloatingLayoutPolicy.minimumUsableWidth && extreme.width <= 420)
            #expect(extreme.height >= DisplayFloatingLayoutPolicy.minimumUsableHeight && extreme.height <= 752)
        }
    }

    @Test("held drag follows the same global touch through frame and container changes")
    func resizedDragRetainsTouch() {
        let touch = CGPoint(x: 190, y: 220)
        let grab = CGPoint(x: 30, y: 30)
        for (container, panel) in [
            (CGRect(x: 0, y: 80, width: 400, height: 700), CGSize(width: 180, height: 500)),
            (CGRect(x: 10, y: 100, width: 380, height: 320), CGSize(width: 220, height: 70))
        ] {
            let safe = DisplayFloatingLayoutPolicy.safeCenterRect(container: container.size, panelSize: panel)
            let center = DisplayFloatingLayoutPolicy.draggedCenter(globalLocation: touch, grabPoint: grab,
                                                                   container: container, panelSize: panel, in: safe)
            #expect(abs(center.x - panel.width / 2 + grab.x + container.minX - touch.x) < 0.001)
            #expect(abs(center.y - panel.height / 2 + grab.y + container.minY - touch.y) < 0.001)
        }
    }

    @Test("floating geometry rejects late frames from a retired source")
    func browserFrameGeometrySourceFence() {
        let route = DisplayRoute(sessionID: "session", display: browserDisplay(id: "browser"))
        let surface = PresentationSurfaceToken(id: "surface", generation: UUID())
        let producerID = UUID()
        func source(activityGeneration: UInt64, presentationIdentity: String, producer: UUID? = nil) -> LiveFrameSource {
            LiveFrameSource(
                sessionID: route.sessionID,
                profileID: "profile",
                presentationIdentity: presentationIdentity,
                viewID: "view",
                generation: "runtime:browser",
                surface: surface,
                producerID: producer ?? producerID,
                activityGeneration: activityGeneration
            )
        }
        let current = source(activityGeneration: 3, presentationIdentity: route.display.presentationIdentity)
        let stale = source(activityGeneration: 2, presentationIdentity: route.display.presentationIdentity)
        let retired = source(activityGeneration: 4, presentationIdentity: "browser:view:retired")
        let geometry = LiveFrameGeometry(width: 1080, height: 1920)
        let currentUpdate = LiveFrameUpdate(source: current, geometry: geometry)
        #expect(DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            currentUpdate, route: route, profileID: "profile", surface: surface,
            allowsPublication: true, previousSource: nil
        ))
        #expect(!DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            LiveFrameUpdate(source: stale, geometry: geometry), route: route,
            profileID: "profile", surface: surface, allowsPublication: true, previousSource: current
        ))
        #expect(!DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            LiveFrameUpdate(source: retired, geometry: geometry), route: route,
            profileID: "profile", surface: surface, allowsPublication: true, previousSource: current
        ))
        #expect(!DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            currentUpdate, route: route, profileID: "profile", surface: surface,
            allowsPublication: false, previousSource: nil
        ))
        for width in [CGFloat.nan, .infinity, 0, -1] {
            #expect(!DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
                .init(source: current, geometry: .init(width: width, height: 100)), route: route,
                profileID: "profile", surface: surface, allowsPublication: true, previousSource: current
            ))
        }
        #expect(!DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            .init(source: stale, geometry: nil), route: route, profileID: "profile", surface: surface,
            allowsPublication: false, previousSource: current
        ))
        let remounted = source(activityGeneration: 1, presentationIdentity: route.display.presentationIdentity, producer: UUID())
        #expect(DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            .init(source: remounted, geometry: geometry), route: route, profileID: "profile", surface: surface,
            allowsPublication: true, previousSource: current
        ))
    }

    private func toolDescriptor(name: String, display: DisplayProjection? = nil) -> ChatToolDescriptor {
        ChatToolPresentation(id: "call", title: name, toolName: name, subtitle: "Completed",
            request: nil, response: nil, content: "", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil,
            display: display).descriptor
    }

    private func browserDisplay(id: String, generation: String = "runtime:browser") -> DisplayProjection {
        DisplayProjection(displayId: id, title: "Browser", altText: "Browser", kind: .browserLive,
            presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet), eligibleSurfaces: [.sheet, .floating],
            fallbackText: "Unavailable", liveView: .init(schema: "tron.browser-live-view.v1", viewId: "view", generation: generation,
                title: "Browser", fallbackText: "Unavailable"))
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

    @Test("floating panel uses the native usable proposal and snaps horizontally")
    func floatingPanelGeometry() {
        let size = DisplayFloatingLayoutPolicy.panelSize(in: CGSize(width: 390, height: 680))
        let safe = DisplayFloatingLayoutPolicy.safeCenterRect(container: CGSize(width: 390, height: 680), panelSize: size)
        #expect(safe.minY == size.height / 2 + 8)
        #expect(safe.maxY == 680 - size.height / 2 - 8)
        let snapped = DisplayFloatingLayoutPolicy.snappedToNearestHorizontalEdge(
            CGPoint(x: safe.midX - 1, y: safe.midY),
            in: safe
        )
        #expect(snapped.x == safe.minX)
        #expect(snapped.y == safe.midY)
        #expect(DisplayFloatingLayoutPolicy.controlTouchTarget >= 44)
    }

    @Test("squeezed placement preserves its dock preference and all content fits")
    func squeezedPanelPlacement() {
        for browser in [false, true] {
            for container in [CGSize(width: 390, height: 80), CGSize(width: 180, height: 120), .zero] {
                let panel = DisplayFloatingLayoutPolicy.panelSize(in: container, live: browser)
                #expect(panel.width <= container.width)
                #expect(panel.height <= container.height)
                let centers = DisplayFloatingLayoutPolicy.safeCenterRect(container: container, panelSize: panel)
                let preferred = UnitPoint.bottomTrailing
                let center = DisplayFloatingLayoutPolicy.center(for: preferred, in: centers)
                let restored = DisplayFloatingLayoutPolicy.anchor(for: center, in: centers, retaining: preferred)
                #expect(restored == preferred)
            }
        }
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

    private func imageDisplay(id: String, revision: Int = 1) -> DisplayProjection {
        DisplayProjection(
            displayId: id, revision: revision,
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
