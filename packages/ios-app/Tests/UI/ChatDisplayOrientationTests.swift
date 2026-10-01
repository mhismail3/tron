import SwiftUI
import PDFKit
import Testing
import UIKit
@testable import TronMobile
@testable import TronMobileCore

/// An asymmetric, fully loaded image distinguishes render orientation from row
/// position. A placeholder or a symmetric thumbnail cannot expose this defect.
@MainActor
enum ChatDisplayOrientationFixture {
    static func snapshot(history: Bool = false, kind: String = "image") throws -> SessionSnapshot {
        var snapshot = try SessionScenarioBuilder(seed: 1_310).openingTail(targetEncodedBytes: 10_000)
        snapshot.transcript = try decodeTranscriptFixture([TranscriptItem].self, from: HostedChatDisplayFixture.imageTranscriptData)
        if kind != "image" {
            var rows = try #require(JSONSerialization.jsonObject(with: HostedChatDisplayFixture.imageTranscriptData) as? [[String: Any]])
            var display = try #require(rows[1]["display"] as? [String: Any])
            display["kind"] = kind
            display["eligibleSurfaces"] = ["sheet", "inline"]
            var artifact = try #require(display["artifact"] as? [String: Any])
            artifact["kind"] = kind
            artifact["name"] = kind == "pdf" ? "orientation.pdf" : "orientation.swift"
            artifact["mimeType"] = kind == "pdf" ? "application/pdf" : "text/plain"
            display["artifact"] = artifact
            rows[1]["display"] = display
            snapshot.transcript = try decodeTranscriptFixture([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        if history {
            snapshot.transcript = SessionScenarioBuilder(seed: 1_310).historyPage(count: 30, longRowBytes: 200) + snapshot.transcript
            // Leave earlier messages unloaded on the server so the oldest loaded
            // row carries the "Load earlier messages" pill above it: the exact
            // state the status-bar jump-to-oldest requirement has to show.
            snapshot.transcriptStart = 15
            snapshot.transcriptTotal = snapshot.transcript.count + 15
        } else {
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = snapshot.transcript.count
        }
        snapshot.toolExecutions = []
        return snapshot
    }

    static func mediaFetch(kind: String = "image") throws -> ChatMediaFetch {
        if kind == "pdf" {
            let bounds = CGRect(x: 0, y: 0, width: 160, height: 160)
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage()
                UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
                UIColor.blue.setFill(); context.cgContext.fill(CGRect(x: 0, y: 80, width: 160, height: 80))
            }
            return { _ in ChatMediaPayload(data: data, mimeType: "application/pdf") }
        }
        if kind == "code" {
            let data = Data("// Upright native code preview\nlet direction = \"top to bottom\"\n".utf8)
            return { _ in ChatMediaPayload(data: data, mimeType: "text/plain") }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 80, width: 160, height: 80))
        }
        let data = try #require(image.pngData())
        return { _ in ChatMediaPayload(data: data, mimeType: "image/png") }
    }

    static func harness(orientation: ChatTranscriptOrientation = .newestAtOrigin, history: Bool = false, kind: String = "image") async throws -> ChatViewScrollHarness {
        try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot(history: history, kind: kind), displayFrameScheduler: .displayLink,
            enablesPresentationCover: true,
            mediaFetch: mediaFetch(kind: kind), orientation: orientation
        )
    }

    static func capture(_ harness: ChatViewScrollHarness) throws -> UIImage {
        let window = try #require(harness.visibleRootView.window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Scan rendered window pixels, not transforms inferred from SwiftUI layout.
    static func colorCenters(_ image: UIImage) throws -> (red: CGPoint, blue: CGPoint)? {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = CGPoint.zero, blue = CGPoint.zero
        var reds = 0, blues = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 160 && bytes[i + 1] < 70 && bytes[i + 2] < 70 {
                    red.x += CGFloat(x); red.y += CGFloat(y); reds += 1
                }
                if bytes[i + 2] > 160 && bytes[i] < 70 && bytes[i + 1] < 70 {
                    blue.x += CGFloat(x); blue.y += CGFloat(y); blues += 1
                }
            }
        }
        guard reds > 500, blues > 500 else { return nil }
        return (CGPoint(x: red.x / CGFloat(reds), y: red.y / CGFloat(reds)),
                CGPoint(x: blue.x / CGFloat(blues), y: blue.y / CGFloat(blues)))
    }

    static func waitForLoadedImage(_ harness: ChatViewScrollHarness) async throws -> UIImage {
        _ = try await harness.recorder.waitUntil { $0.observation.isReady }
        for _ in 0..<60 {
            try await harness.driveFrameBoundary()
            let image = try capture(harness)
            if try colorCenters(image) != nil { return image }
        }
        throw CocoaError(.fileReadUnknown)
    }
}

@MainActor
@Suite(.serialized)
struct ChatDisplayOrientationTests {
    @Test("composer-owned managed sheets reset inherited secondary-scroll policy for both presentation forms")
    func managedSheetRestoresStatusBarOwnership() async throws {
        for itemBased in [false, true] {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: AnyView(StatusBarSheetInheritanceFixture(itemBased: itemBased)))
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                host.rootView = AnyView(EmptyView())
                window.isHidden = true
                window.rootViewController = nil
            }
            func document(in view: UIView) -> TronDocumentTextView? {
                if let text = view as? TronDocumentTextView { return text }
                return view.subviews.lazy.compactMap { document(in: $0) }.first
            }
            for _ in 0..<90 where host.presentedViewController?.view.flatMap({ document(in: $0) }) == nil {
                try await DisplayFrameScheduler.displayLink.nextFrame()
            }
            for _ in 0..<24 { try await DisplayFrameScheduler.displayLink.nextFrame() }
            let presented = try #require(host.presentedViewController?.view)
            let text = try #require(document(in: presented))
            #expect(!text.text.isEmpty && text.window === window)
            #expect(text.scrollsToTop, "The sheet, not its covered composer, owns status-bar scrolling (item=\(itemBased))")
        }
    }

    @Test("display preview lifts the single mounted upright card with an identity window target")
    func inlineImagePreviewTargetsMountedCard() async throws {
        for orientation in [ChatTranscriptOrientation.newestAtOrigin] {
            let harness = try await ChatDisplayOrientationFixture.harness(orientation: orientation)
            do {
                _ = try await ChatDisplayOrientationFixture.waitForLoadedImage(harness)
                let sources = harness.promptContextMenuSurfaces().filter {
                    $0.owner.actions.contains { $0.title == "Tool Details" }
                        && !$0.view.isHidden && $0.view.alpha > 0.01 && $0.view.window != nil
                }
                #expect(sources.count == 1, "\(orientation): one actual card source, got \(sources.count)")
                for source in sources {
                    let frame = source.view.convert(source.view.bounds, to: nil)
                    let configuration = try #require(source.owner.contextMenuInteraction(source.interaction,
                        configurationForMenuAtLocation: CGPoint(x: source.view.bounds.midX, y: source.view.bounds.midY)))
                    let identifier = configuration.identifier ?? ("card" as NSString)
                    let highlight = source.owner.contextMenuInteraction(source.interaction, configuration: configuration,
                        highlightPreviewForItemWithIdentifier: identifier)
                    let dismissal = source.owner.contextMenuInteraction(source.interaction, configuration: configuration,
                        dismissalPreviewForItemWithIdentifier: identifier)
                    for preview in [highlight, dismissal] {
                        let preview = try #require(preview)
                        let container = try #require(preview.target.container as? UIView)
                        let center = container.convert(preview.target.center, to: nil)
                        #expect(preview.view === source.view, "Lift the real card, not replacement content")
                        #expect(preview.target.transform == .identity)
                        #expect(!TranscriptWindowOracle.isFlipped(container))
                        #expect(!TranscriptWindowOracle.isFlipped(preview.view))
                        #expect(abs(center.x - frame.midX) <= 0.5 && abs(center.y - frame.midY) <= 0.5)
                        #expect(preview.view.bounds.width > 50 && preview.view.bounds.height > 50)
                    }
                }
            } catch { await harness.close(); throw error }
            await harness.close()
        }
    }

    @Test("native inline PDF and code renderers remain upright and cannot compete for status-bar ownership")
    func nativeInlineRenderers() async throws {
        for orientation in [ChatTranscriptOrientation.newestAtOrigin] {
            for kind in ["pdf", "code"] {
                let harness = try await ChatDisplayOrientationFixture.harness(orientation: orientation, kind: kind)
                do {
                    _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                    for _ in 0..<60 { try await harness.driveFrameBoundary() }
                    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                    let views = descendants(harness.visibleRootView)
                    let renderer = try #require(views.first { kind == "pdf" ? $0 is PDFView : $0 is TronDocumentTextView })
                    #expect(!TranscriptWindowOracle.isFlipped(renderer), "\(orientation)/\(kind)")
                    let eligible = descendants(try #require(harness.visibleRootView.window)).compactMap { $0 as? UIScrollView }.filter(\.scrollsToTop)
                    #expect(eligible.count == 1, "\(orientation)/\(kind): \(eligible)")
                    let image = try ChatDisplayOrientationFixture.capture(harness)
                    if kind == "pdf" {
                        let colors = try #require(try ChatDisplayOrientationFixture.colorCenters(image))
                        #expect(colors.red.y < colors.blue.y)
                    }
                    Attachment.record(try #require(image.pngData()), named: "inline-\(kind)-\(orientation).png")
                } catch { await harness.close(); throw error }
                await harness.close()
            }
        }
    }

    @Test("one status-bar recipient survives empty composer, attachments, chips and catalog; origin delegate detaches to oldest")
    func statusBarRecipientAndOldestHistory() async throws {
        for orientation in [ChatTranscriptOrientation.newestAtOrigin] {
            let harness = try await ChatDisplayOrientationFixture.harness(orientation: orientation, history: true)
            do {
                _ = try await ChatDisplayOrientationFixture.waitForLoadedImage(harness)
                try await harness.loadCanonicalCommands(["review"], skills: ["skill:review"])
                let transcript = try harness.nativeTranscriptScrollViewForTesting()
                let originalDelegate = transcript.delegate
                func scrolls(in view: UIView) -> [UIScrollView] {
                    ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrolls(in: $0) }
                }
                for state in ["empty", "attachments", "chips", "catalog"] {
                    switch state {
                    case "attachments": try harness.setMotionAccessory(.photo)
                    case "chips": try harness.setComposerAccessories(true)
                    case "catalog": harness.probe.composerResourcePickerPresentation?(.skills)
                    default: break
                    }
                    for _ in 0..<24 { try await harness.driveFrameBoundary() }
                    let window = try #require(harness.visibleRootView.window)
                    let eligible = scrolls(in: window).filter { $0.scrollsToTop }
                    #expect(eligible.count == 1, "\(orientation)/\(state): \(eligible)")
                    #expect(transcript.delegate === originalDelegate, "Never replace SwiftUI's delegate")
                    let recipient = try #require(eligible.first)
                    #expect(recipient !== transcript)
                    #expect(recipient.delegate is ChatTranscriptStatusBar.Probe)
                }
                harness.probe.composerResourcePickerPresentation?(nil)
                try harness.setComposerAccessories(false)
                for _ in 0..<24 { try await harness.driveFrameBoundary() }
                let window = try #require(harness.visibleRootView.window)
                let recipient = try #require(scrolls(in: window).first { $0.scrollsToTop })
                let delegate = try #require(recipient.delegate)
                #expect(delegate.scrollViewShouldScrollToTop?(recipient) == false)
                for _ in 0..<90 { try await harness.driveFrameBoundary() }
                #expect(harness.probeObservation.isDetached)
                let oldest = try #require(harness.visuallyTopmostOnScreenRow())
                #expect(oldest.semanticID == harness.firstTranscriptID, "Reached \(oldest.semanticID)")
                let visibleRows = harness.probeObservation.visibleRowIDs
                #expect(visibleRows.contains(harness.firstTranscriptID))
                #expect(visibleRows.contains("earlier-messages"))
                // The origin layout reports each row's frame with the newest row
                // at the content origin and coordinates growing toward older
                // history; the render flip then draws larger-y content higher on
                // screen. The pill therefore renders above the oldest loaded row
                // exactly when its older edge is at or beyond that row's.
                let frames = harness.probeObservation.rowFrames
                let pillFrame = try #require(frames["earlier-messages"])
                let oldestFrame = try #require(frames[harness.firstTranscriptID])
                #expect(pillFrame.minY >= oldestFrame.maxY - 1, "The load-earlier pill renders above the oldest loaded row")
                harness.captureScreenshot(named: "status-bar-origin-oldest.png")
                harness.setCovered(true)
                for _ in 0..<12 { try await harness.driveFrameBoundary() }
                #expect(transcript.scrollsToTop, "Coverage restores the original native setting")
                #expect(!scrolls(in: window).contains { $0.delegate is ChatTranscriptStatusBar.Probe })
            } catch { await harness.close(); throw error }
            await harness.close()
        }
    }

    @Test("loaded inline image renders upright in window pixels on the origin-anchored transcript")
    func inlineImageRendersUpright() async throws {
        for orientation in [ChatTranscriptOrientation.newestAtOrigin] {
            let harness = try await ChatDisplayOrientationFixture.harness(orientation: orientation)
            do {
                harness.visibleRootView.window?.overrideUserInterfaceStyle = .dark
                _ = try await ChatDisplayOrientationFixture.waitForLoadedImage(harness)
                for _ in 0..<24 { try await harness.driveFrameBoundary() }
                let image = try ChatDisplayOrientationFixture.capture(harness)
                let colors = try #require(try ChatDisplayOrientationFixture.colorCenters(image))
                #expect(colors.red.y < colors.blue.y, "\(orientation): red \(colors.red), blue \(colors.blue)")
                Attachment.record(try #require(image.pngData()), named: "inline-image-\(orientation).png")
            } catch {
                await harness.close()
                throw error
            }
            await harness.close()
        }
    }
}

/// Reproduces the environment inherited by the composer's resource-detail sheets.
/// The real managed presentation and native document scroll are retained, with no
/// synthetic delegate or replacement UI to mask the owning-boundary defect.
@MainActor
private struct StatusBarSheetInheritanceFixture: View {
    let itemBased: Bool
    private struct Route: Identifiable { let id = "resource-detail" }
    @State private var item: Route?
    @State private var presented = false
    var body: some View {
        Group {
            if itemBased {
                Color.clear.tronManagedSheet(item: $item, identity: { $0.id }) { _ in
                    TronReadOnlyTextView(text: String(repeating: "A resource document line.\n", count: 100))
                }
            } else {
                Color.clear.tronManagedSheet(isPresented: $presented, identity: "resource-detail") {
                    TronReadOnlyTextView(text: String(repeating: "A resource document line.\n", count: 100))
                }
            }
        }
        .environment(\.chatOwnsStatusBar, true)
        .environment(\.scenePhase, .active)
        .tronPresentation()
        .task {
            if itemBased { item = Route() } else { presented = true }
        }
    }
}
