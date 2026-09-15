import AppKit
import SwiftUI
import Testing
@testable import TronMac

@Suite("Permission setup layout", .serialized)
@MainActor
struct PermissionSetupLayoutTests {
    @Test("helper control stays neutral until its first status probe returns")
    func helperLoadingState() {
        #expect(PermissionsStepContent.serviceActionTitle(for: nil) == "Checking Helper…")
        #expect(PermissionsStepContent.serviceActionTitle(for: .needsRegistration) == "Enable Helper")
        #expect(PermissionsStepContent.serviceActionTitle(for: .enabled) == "Restart Helper")
    }

    @Test("retired probes cannot publish state")
    func retiredProbeFence() {
        let probeID = UUID()
        #expect(PermissionsStepContent.presentationIsCurrent(active: true,
                                                             requestID: probeID,
                                                             currentID: probeID))
        #expect(!PermissionsStepContent.presentationIsCurrent(active: false,
                                                              requestID: probeID,
                                                              currentID: probeID))
        #expect(!PermissionsStepContent.presentationIsCurrent(active: true,
                                                              requestID: probeID,
                                                              currentID: UUID()))
    }

    @Test("settings window fits a normal display and bounds constrained displays")
    func settingsWindowSizing() {
        let normal = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(PermissionSettingsWindowLayout.initialContentSize(for: normal)
                == PermissionSettingsWindowLayout.idealContentSize)

        let constrained = CGRect(x: 0, y: 0, width: 520, height: 500)
        let initial = PermissionSettingsWindowLayout.initialContentSize(for: constrained)
        let maximum = PermissionSettingsWindowLayout.maximumContentSize(for: constrained)
        let minimum = PermissionSettingsWindowLayout.minimumContentSize(for: constrained)
        #expect(initial.width <= maximum.width)
        #expect(initial.height <= maximum.height)
        #expect(minimum.width <= initial.width)
        #expect(minimum.height <= initial.height)
    }

    @Test("hosted permissions window fits its content within the visible frame")
    func hostedPermissionsWindowFits() async throws {
        let probeGate = PermissionLayoutProbeGate()
        var setup = EnvironmentSetup.live
        setup.canManageLaunchAgent = false
        setup.nativeHostServiceState = { .enabled }
        setup.probePermissions = {
            let result: [Permission: PermissionStatus] = [.fullDiskAccess: .granted,
                                                           .accessibility: .granted,
                                                           .screenRecording: .granted]
            await probeGate.completeProbe()
            return result
        }
        let controller = PermissionSettingsWindow(setup: setup, onClose: {})
        guard let window = controller.window else { Issue.record("Permission window was not created"); return }
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // NSHostingView does not settle SwiftUI geometry callbacks while its
        // window remains hidden. This is a test-owned surface; presenting it
        // makes the oracle observe the same rendered lifecycle as production.
        controller.showWindow(nil)
        window.displayIfNeeded()
        let visible = window.screen?.visibleFrame ?? PermissionSettingsWindowLayout.fallbackVisibleFrame
        let maximum = PermissionSettingsWindowLayout.maximumContentSize(for: visible)
        // The fake probe and rendered fit are separate gates. Waiting for a
        // repeated sample count can settle before either owner has completed.
        var renderedFit = false
        for _ in 0..<200 {
            window.displayIfNeeded()
            if let scroll = descendants(window.contentView ?? NSView()).compactMap({ $0 as? NSScrollView }).first,
               let document = scroll.documentView {
                let frame = window.contentRect(forFrameRect: window.frame)
                renderedFit = document.frame.height > 0
                    && frame.height <= maximum.height + 1
                    && (document.frame.height <= scroll.contentSize.height + 1 || frame.height >= maximum.height - 1)
            }
            if await probeGate.probeCompleted && renderedFit { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probeGate.probeCompleted)
        #expect(renderedFit)
        let fitted = window.contentRect(forFrameRect: window.frame).size
        #expect(fitted.width <= maximum.width + 1)
        #expect(fitted.height <= maximum.height + 1)
        #expect(visible.insetBy(dx: 12, dy: 12).contains(window.frame))
        let view = try #require(window.contentView)
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > 0)
        #expect(document.frame.width <= scroll.contentSize.width + 1)
        if document.frame.height + 48 <= maximum.height {
            // On a normal display the final AppKit content rect contains the
            // entire document, rather than merely reporting a matching min.
            #expect(document.frame.height <= scroll.contentSize.height + 1)
            #expect(fitted.height + 1 >= document.frame.height + 40)
        } else {
            // A bounded display intentionally falls back to scrolling while
            // keeping the actual viewport within the visible-frame cap.
            #expect(document.frame.height > scroll.contentSize.height)
            #expect(fitted.height <= maximum.height + 1)
        }
        attach(view, name: "mac-permissions-fitted.png")
    }

    @Test("permissions window animation follows Reduce Motion")
    func permissionsWindowAnimationPolicy() {
        #expect(PermissionSettingsWindowLayout.shouldAnimate(isVisible: true, reduceMotion: false))
        #expect(!PermissionSettingsWindowLayout.shouldAnimate(isVisible: true, reduceMotion: true))
        #expect(!PermissionSettingsWindowLayout.shouldAnimate(isVisible: false, reduceMotion: false))
    }

    @Test("all permission rows remain reachable inside the fixed wizard proposal")
    func boundedScrollableContent() async throws {
        var setup = EnvironmentSetup.live
        setup.canManageLaunchAgent = false
        setup.nativeHostServiceState = { .enabled }
        setup.probePermissions = { Permission.allCases.reduce(into: [:]) { $0[$1] = .granted } }
        setup.requestPermission = { _ in Issue.record("Unexpected TCC request from layout"); return .probeUnavailable }
        setup.enableNativeHost = { Issue.record("Unexpected registration from layout"); return .unavailable }
        setup.refreshNativeHost = { Issue.record("Unexpected refresh from layout"); return .unavailable }
        let size = CGSize(width: 480 - 2 * WizardLayout.horizontalPadding,
                          height: 440 - WizardLayout.topPadding - WizardLayout.headerHeight
                            - WizardLayout.headerBodySpacing - WizardLayout.bottomPadding - WizardLayout.bottomBarHeight)
        let view = NSHostingView(rootView: PermissionSetupView(statuses: .constant([.fullDiskAccess: .granted]))
            .environment(\.environmentSetup, setup).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var scrolling: NSScrollView?
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            scrolling = descendants(view).compactMap { $0 as? NSScrollView }.first
            if let scrolling, let document = scrolling.documentView,
               document.frame.height > scrolling.contentSize.height { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scroll = try #require(scrolling)
        let document = try #require(scroll.documentView)
        #expect(scroll.contentSize.height <= size.height)
        #expect(document.frame.width <= scroll.contentSize.width + 1)
        #expect(document.frame.height > scroll.contentSize.height)
        attach(view, name: "mac-permissions-top.png")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y > 0)
        attach(view, name: "mac-permissions-bottom.png")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func attach(_ view: NSView, name: String) {
        // Capture the hosted hierarchy through AppKit first. `display` with a
        // manually installed context does not reliably traverse NSHostingView.
        guard let source = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("Could not allocate source bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: source)
        guard let sourceImage = source.cgImage,
              let destination = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: source.pixelsWide,
                  pixelsHigh: source.pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bitmapFormat: .alphaFirst,
                  bytesPerRow: 0,
                  bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: destination) else {
            Issue.record("Could not allocate destination bitmap for \(name)")
            return
        }

        let destinationRect = CGRect(x: 0, y: 0,
                                     width: destination.pixelsWide,
                                     height: destination.pixelsHigh)
        let appearance = view.effectiveAppearance
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            // Composite onto a distinct opaque destination so the exported
            // evidence has a resolved window background and alpha of 1.
            NSColor.windowBackgroundColor.setFill()
            destinationRect.fill()
            context.cgContext.draw(sourceImage, in: destinationRect)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = destination.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            Issue.record("Could not encode destination bitmap for \(name)")
            return
        }
        let evidence = pixelEvidence(for: destination, background: appearance)
        #expect(evidence.opaquePixels == evidence.totalPixels,
                "\(name) must have fully opaque pixels")
        #expect(evidence.nonBackgroundPixels >= max(128, evidence.totalPixels / 1000),
                "\(name) must contain substantial non-background content; found \(evidence.nonBackgroundPixels) differing pixels")
        if let outputDirectory = ProcessInfo.processInfo.environment["TRON_OPAQUE_CAPTURE_OUTPUT_DIR"] {
            let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                .appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try png.write(to: outputURL)
                print("opaque-capture path=\(outputURL.path) dimensions=\(destination.pixelsWide)x\(destination.pixelsHigh) total=\(evidence.totalPixels) opaque=\(evidence.opaquePixels) nonbackground=\(evidence.nonBackgroundPixels)")
            } catch {
                Issue.record("Could not write \(outputURL.path): \(error)")
            }
        }
        Attachment.record(png, named: name)
    }

    private struct PixelEvidence {
        let totalPixels: Int
        let opaquePixels: Int
        let nonBackgroundPixels: Int
    }

    private func pixelEvidence(for bitmap: NSBitmapImageRep,
                               background appearance: NSAppearance) -> PixelEvidence {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let total = width * height
        guard let image = bitmap.cgImage else {
            return PixelEvidence(totalPixels: total, opaquePixels: 0, nonBackgroundPixels: 0)
        }
        var resolvedBackground: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedBackground = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
        }
        guard let background = resolvedBackground,
              let components = background.cgColor.components,
              components.count >= 3 else {
            return PixelEvidence(totalPixels: total, opaquePixels: 0, nonBackgroundPixels: 0)
        }
        let backgroundComponents = (0..<3).map { UInt8(components[$0] * 255.0 + 0.5) }
        var pixels = [UInt8](repeating: 0, count: total * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return PixelEvidence(totalPixels: total, opaquePixels: 0, nonBackgroundPixels: 0) }
        var opaque = 0
        var differing = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[index + 3]
            if alpha == 255 { opaque += 1 }
            if zip(0..<3, backgroundComponents).contains(where: { channel, expected in
                abs(Int(pixels[index + channel]) - Int(expected)) > 12
            }) {
                differing += 1
            }
        }
        return PixelEvidence(totalPixels: total, opaquePixels: opaque, nonBackgroundPixels: differing)
    }
}

private actor PermissionLayoutProbeGate {
    private(set) var probeCompleted = false
    func completeProbe() { probeCompleted = true }
}
