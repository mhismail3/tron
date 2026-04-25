import SwiftUI
import AppKit
import Darwin

/// Permissions step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / Continue, with Continue gated by
/// all three grants in `WizardShell.permissionsCanContinue`). This
/// view contributes the description, the three permission cards each
/// with their own "Open Settings" deep-link, a Screen Recording app
/// shortcut for macOS's manual-add path, and an inline Re-check link.
///
/// This step runs AFTER Install (see `WizardStep.allCases` ordering
/// test) on purpose. macOS ties sandbox/TCC extensions to the process
/// that was launched when the grant was made, so granting FDA to the
/// agent before it exists would prompt the user for a permission they
/// can't satisfy. By the time the wizard gets here the agent bundle
/// is already on disk at `~/.tron/system/Tron.app` and the LaunchAgent
/// is running — the user grants permissions to "Tron Server" in
/// System Settings. When they return from a Settings pane opened via
/// this step, we consume that single round-trip, `launchctl kickstart
/// -k` the agent when the permission was previously missing, and then
/// re-probe so the new grant takes effect without a visible restart
/// prompt.
///
/// The three categories map 1:1 to the macOS TCC probes exposed by the
/// agent's `system.probePermissions` RPC. The wizard polls that RPC
/// (rather than probing the wrapper's own TCC state) because the agent
/// is the binary that actually runs the Computer-Use tool and the file
/// tools — the wrapper itself never touches FDA / Screen Recording /
/// Accessibility at runtime.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var appActivationObserver: NSObjectProtocol?
    @State private var pollTask: Task<Void, Never>?
    @State private var settingsGrantWatchTask: Task<Void, Never>?
    @State private var checkingPermissions = false
    @State private var pendingSettingsReturn: PermissionSettingsReturn?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PermissionsStepContent.intro)
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                permissionRow(.fullDiskAccess,
                              title: "Full Disk Access",
                              detail: "Lets Tron read and edit files.",
                              instruction: PermissionsStepContent.defaultInstruction)
                permissionRow(.screenRecording,
                              title: "Screen Recording",
                              detail: "Lets Tron see your screen.",
                              instruction: PermissionsStepContent.screenRecordingInstruction)
                permissionRow(.accessibility,
                              title: "Accessibility",
                              detail: "Lets Tron click and type for you.",
                              instruction: PermissionsStepContent.defaultInstruction)
            }
            .padding(.vertical, 1)

            Button {
                Task { await refreshAll(kickstart: true, showActivity: true) }
            } label: {
                Label(checkingPermissions ? "Checking permissions…" : "Re-check permissions",
                      systemImage: checkingPermissions ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.wizardLink)
            .padding(.leading, PermissionsStepLayout.recheckLeadingPadding)
            .disabled(checkingPermissions)
        }
        .task { await startPolling() }
        .onAppear { installAppActivationObserver() }
        .onDisappear { teardown() }
    }

    // MARK: - Row + badge

    @ViewBuilder
    private func permissionRow(
        _ permission: Permission,
        title: String,
        detail: String,
        instruction: String
    ) -> some View {
        let status = state.permissionStatuses[permission] ?? .notDetermined
        WizardInfoCard(
            verticalPadding: PermissionsStepLayout.cardVerticalPadding,
            horizontalPadding: PermissionsStepLayout.cardHorizontalPadding
        ) {
            WizardIconTextRow(
                iconColumnWidth: PermissionsStepLayout.statusIconColumnWidth,
                iconTextSpacing: PermissionsStepLayout.iconTextSpacing
            ) {
                statusBadge(status)
            } content: {
                VStack(alignment: .leading, spacing: PermissionsStepLayout.textLineSpacing) {
                    Text(title).font(TronTypography.wizardHeadline)
                    Text(detail)
                        .font(TronTypography.wizardBodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.92)
                    Text(instruction)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
            } trailing: {
                HStack(spacing: PermissionsStepLayout.trailingControlSpacing) {
                    if permission == .screenRecording {
                        ScreenRecordingAppShortcut(appURL: setup.installedBundle)
                            .frame(
                                width: PermissionsStepLayout.appShortcutHitSize,
                                height: PermissionsStepLayout.appShortcutHitSize
                            )
                    }

                    Button {
                        openPermissionSettings(permission, statusBeforeOpen: status)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.wizardTertiary)
                    .help("Open Settings")
                    .accessibilityLabel("Open Settings for \(title)")
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
                .foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
                .foregroundStyle(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
                .foregroundStyle(.orange)
        case .probeUnavailable:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Opens the relevant Settings pane. Screen Recording gets one
    /// extra step first: macOS does not add an app to that list just
    /// because Settings opened. The process that needs capture access
    /// must request it once, so we ask the already-installed agent to
    /// call `CGRequestScreenCaptureAccess()` before showing the pane.
    private func openPermissionSettings(_ permission: Permission, statusBeforeOpen: PermissionStatus) {
        guard permission == .screenRecording, statusBeforeOpen != .granted else {
            openSettingsPane(permission, statusBeforeOpen: statusBeforeOpen)
            return
        }

        Task {
            async let requestSucceeded = setup.requestAgentPermission(permission)
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run {
                openSettingsPane(permission, statusBeforeOpen: statusBeforeOpen)
            }
            _ = await requestSucceeded
        }
    }

    private func openSettingsPane(_ permission: Permission, statusBeforeOpen: PermissionStatus) {
        pendingSettingsReturn = PermissionSettingsReturn(
            permission: permission,
            statusBeforeOpen: statusBeforeOpen
        )
        startSettingsGrantWatch(for: permission)
        NSWorkspace.shared.open(PermissionDeepLink.url(for: permission))
    }

    // MARK: - Polling + kickstart lifecycle

    /// Starts the 2 s agent-probe poll loop. Runs until the view
    /// disappears or all three grants are observed, whichever comes
    /// first. The loop is re-entrant — calling this twice is a no-op
    /// thanks to the `pollTask` guard.
    private func startPolling() async {
        // Seed the state before the recurring 2 s loop. On revisits,
        // refresh immediately so stale grants correct as soon as the
        // step appears. On the first visit, the status dictionary is
        // empty and the whole page is still in its slide transition. If
        // the probe resolves during that animation, SwiftUI can insert
        // the newly-resolved SF Symbol badges at their final
        // coordinates while the rest of the card is still moving.
        // Waiting one shell transition keeps the first resolved badge
        // render inside the same moving page subtree.
        if state.permissionStatuses.isEmpty {
            try? await Task.sleep(nanoseconds: PermissionsStepContent.initialProbeDelayNanoseconds)
            if Task.isCancelled { return }
        }

        await refreshAll(kickstart: false, showActivity: false)

        guard pollTask == nil else { return }
        pollTask = Task { [weak state = self.state] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                if Task.isCancelled { break }
                let snapshot = await setup.probeAgentPermissions()
                await MainActor.run {
                    guard let state else { return }
                    for (permission, status) in snapshot {
                        state.permissionStatuses[permission] = status
                    }
                }
                // Stop polling once everything is granted — no point
                // hammering the RPC when the user is still on this
                // step admiring their green badges.
                let allGranted = await MainActor.run { [weak state] in
                    Permission.allCases.allSatisfy { p in
                        (state?.permissionStatuses[p]) == .granted
                    }
                }
                if allGranted { break }
            }
        }
    }

    /// Installs an observer on `NSApp.didBecomeActiveNotification`.
    /// When the user comes back to the wrapper, we first check whether
    /// that activation corresponds to a Settings pane opened by this
    /// view. Plain app activation is only a recheck; otherwise clicking
    /// around System Settings can repeatedly restart the server.
    ///
    /// The observer is stored as a `@State` token so `onDisappear` can
    /// remove it — SwiftUI will recreate the view each time the user
    /// navigates to this step, so leaving the observer attached would
    /// leak one per visit.
    private func installAppActivationObserver() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await handleAppActivation()
            }
        }
    }

    private func teardown() {
        pollTask?.cancel()
        pollTask = nil
        settingsGrantWatchTask?.cancel()
        settingsGrantWatchTask = nil
        if let token = appActivationObserver {
            NotificationCenter.default.removeObserver(token)
            appActivationObserver = nil
        }
    }

    /// Starts a short-lived background watcher after the user opens a
    /// Settings pane from this page. Plain polling can read stale grant
    /// state from the already-running launchd agent; this watcher
    /// periodically restarts and reprobes until the specific permission
    /// turns green. The Re-check button uses the same stronger refresh
    /// path as a manual fallback.
    private func startSettingsGrantWatch(for permission: Permission) {
        settingsGrantWatchTask?.cancel()
        guard (state.permissionStatuses[permission] ?? .notDetermined) != .granted else {
            return
        }

        settingsGrantWatchTask = Task { @MainActor in
            for _ in 0..<PermissionsStepContent.settingsGrantWatchAttempts {
                try? await Task.sleep(nanoseconds: PermissionsStepContent.settingsGrantWatchIntervalNanoseconds)
                if Task.isCancelled { return }
                guard state.step == .permissions else { return }
                guard pendingSettingsReturn?.permission == permission else { return }

                await refreshAll(kickstart: true, showActivity: false)

                if state.permissionStatuses[permission] == .granted {
                    pendingSettingsReturn = nil
                    return
                }
            }
        }
    }

    /// One-shot agent probe. When `kickstart` is true, we first
    /// `launchctl kickstart -k` the agent — this is the seamless
    /// restart that lets a freshly-granted FDA extension take effect
    /// without the user ever seeing the "Tron Server must quit"
    /// dialog. Best-effort: if kickstart fails (launchd refuses for
    /// any reason), we fall through to a plain probe so the UI still
    /// reflects real state.
    private func refreshAll(kickstart: Bool, showActivity: Bool) async {
        if kickstart {
            if showActivity {
                checkingPermissions = true
            }
            defer {
                if showActivity {
                    checkingPermissions = false
                }
            }
            _ = await setup.launchAgentManager.restart(label: TronPaths.launchAgentLabel)
            // Wait for the first successful ping after restart. The
            // agent comes up in ~500 ms on warm starts but we budget
            // generously so a slow first launch doesn't show a false
            // "denied" flash while the RPC socket is still reopening.
            let token = setup.readBearerToken()
            for _ in 0..<20 {
                switch await setup.pingServer(token) {
                case .success, .unauthorized:
                    // Agent is up (even on auth error, the process is
                    // running and answering RPCs).
                    let snapshot = await setup.probeAgentPermissions()
                    for (permission, status) in snapshot {
                        state.permissionStatuses[permission] = status
                    }
                    return
                case .unreachable, .timeout, .malformedResponse:
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        let snapshot = await setup.probeAgentPermissions()
        for (permission, status) in snapshot {
            state.permissionStatuses[permission] = status
        }
    }

    /// Wrapper for the app-activation path. The pending Settings
    /// round-trip is consumed before awaiting so repeated activation
    /// notifications from the same System Settings visit cannot enqueue
    /// repeated `launchctl kickstart -k` calls.
    private func handleAppActivation() async {
        guard state.step == .permissions else { return }
        let pendingReturn = pendingSettingsReturn
        pendingSettingsReturn = nil

        switch PermissionSettingsReturnPolicy.action(for: pendingReturn) {
        case .recheckOnly:
            await refreshAll(kickstart: false, showActivity: false)
        case .restartAndRecheck:
            await refreshAll(kickstart: true, showActivity: true)
        }
    }
}

private struct ScreenRecordingAppShortcut: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> DraggableAppShortcutView {
        let view = DraggableAppShortcutView()
        view.configure(appURL: appURL)
        return view
    }

    func updateNSView(_ nsView: DraggableAppShortcutView, context: Context) {
        nsView.configure(appURL: appURL)
    }
}

private final class DraggableAppShortcutView: NSView, NSDraggingSource {
    private var appURL: URL?
    private var appIcon = NSImage.tronFallbackAppIcon
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    private var dragStartedInMouseSequence = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = PermissionsStepLayout.appShortcutHitSize
        return NSSize(width: size, height: size)
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func configure(appURL: URL) {
        self.appURL = appURL
        toolTip = "Drag Tron.app into the Screen Recording list, or click to reveal it in Finder"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tron app shortcut for Screen Recording")
        appIcon = Self.icon(for: appURL)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        NSShadow.appIconLiftShadow.set()
        appIcon.draw(in: iconDrawingRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        dragStartedInMouseSequence = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let appURL, FileManager.default.fileExists(atPath: appURL.path) else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint, hypot(point.x - start.x, point.y - start.y) < 3 {
            return
        }

        didStartDrag = true
        dragStartedInMouseSequence = true

        let item = NSDraggingItem(pasteboardWriter: Self.dragPasteboardItem(for: appURL))
        let dragRect = iconDrawingRect
        item.setDraggingFrame(dragRect, contents: appIcon)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            dragStartedInMouseSequence = false
        }

        guard !didStartDrag,
              !dragStartedInMouseSequence,
              let appURL,
              FileManager.default.fileExists(atPath: appURL.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        didStartDrag = false
        mouseDownPoint = nil
    }

    private static func dragPasteboardItem(for appURL: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(appURL.absoluteString, forType: .fileURL)
        item.setString(appURL.absoluteString, forType: .URL)
        item.setString(appURL.path, forType: .string)
        item.setPropertyList(
            [appURL.path],
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        )
        return item
    }

    private static func icon(for appURL: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: appURL.path) {
            let image = NSWorkspace.shared.icon(forFile: appURL.path)
            image.size = NSSize(
                width: PermissionsStepLayout.appShortcutIconSize,
                height: PermissionsStepLayout.appShortcutIconSize
            )
            return image
        }
        return NSImage(named: "AppIcon")
            ?? NSImage.tronFallbackAppIcon
    }

    private var iconDrawingRect: NSRect {
        let iconSize = PermissionsStepLayout.appShortcutIconSize
        return NSRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
    }
}

private extension NSImage {
    static var tronFallbackAppIcon: NSImage {
        NSImage(named: "AppIcon")
            ?? NSImage(size: NSSize(
                width: PermissionsStepLayout.appShortcutIconSize,
                height: PermissionsStepLayout.appShortcutIconSize
            ))
    }
}

private extension NSShadow {
    static var appIconLiftShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 8
        return shadow
    }
}

enum PermissionsStepContent {
    static let intro = "Tron needs these permissions to use your computer for you."
    static let defaultInstruction = "Click gear and enable Tron."
    static let screenRecordingInstruction =
        "Click gear, then drag this icon into the first app list."
    static let initialProbeDelayNanoseconds: UInt64 = 520_000_000
    static let settingsGrantWatchAttempts = 45
    static let settingsGrantWatchIntervalNanoseconds: UInt64 = 1_000_000_000
}

enum PermissionsStepLayout {
    static let cardHorizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 9
    static let statusIconColumnWidth: CGFloat = 26
    static let statusIconSize: CGFloat = 23
    static let iconTextSpacing: CGFloat = 9
    static let textLineSpacing: CGFloat = 2
    static let recheckLeadingPadding: CGFloat = cardHorizontalPadding
        + ((statusIconColumnWidth - 16) / 2)
    static let trailingControlSpacing: CGFloat = 5
    static let appShortcutIconSize: CGFloat = 27
    static let appShortcutHitSize: CGFloat = 40
}
