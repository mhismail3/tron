import AppKit
import SwiftUI
import Testing
@testable import TronMac

@Suite("Permission setup layout", .serialized)
@MainActor
struct PermissionSetupLayoutTests {
    @Test("all permission rows remain reachable inside the fixed wizard proposal")
    func boundedScrollableContent() async throws {
        var setup = EnvironmentSetup.live
        setup.canManageLaunchAgent = false
        setup.nativeHostServiceState = { .enabled }
        setup.probePermissions = { [.fullDiskAccess: .granted, .accessibility: .notDetermined,
                                    .screenRecording: .notDetermined] }
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
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { Attachment.record(png, named: name) }
    }
}
