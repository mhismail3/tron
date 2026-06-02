import SwiftUI
import AppKit
import Darwin

/// Permissions step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / Continue, with Continue gated by
/// all three grants in `WizardShell.permissionsCanContinue`). This
/// view contributes the description, the three permission cards each
/// with their own "Open Settings" deep-link and an inline Re-check link.
///
/// This step runs AFTER Install (see `WizardStep.allCases` ordering
/// test) on purpose. macOS ties sandbox/TCC extensions to the process
/// that was launched when the grant was made, so granting FDA to the
/// agent before it exists would prompt the user for a permission they
/// can't satisfy. By the time the wizard gets here the agent bundle
/// is already embedded at `Tron.app/Contents/Library/LoginItems/Tron Server.app`
/// and the LaunchAgent is running. The LaunchAgent associates the helper
/// with the wrapper bundle IDs, so macOS surfaces all three privacy rows
/// under the responsible wrapper app (`Tron.app` in Release,
/// `TronMac.app` in Debug). Returning from Settings, pressing Re-check,
/// and the background watcher are all fast native wrapper probes. Hidden
/// server restarts make the UI feel stuck and produce transient
/// "unknown" states while launchd is cycling the helper; explicit
/// restart remains a menu-bar action outside this wizard page.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var appActivationObserver: NSObjectProtocol?
    @State private var pollTask: Task<Void, Never>?
    @State private var settingsGrantWatchTask: Task<Void, Never>?
    @State private var checkingPermissions = false
    @State private var settingsReturnPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PermissionsStepContent.intro)
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                permissionRow(.fullDiskAccess,
                              title: "Full Disk Access",
                              detail: "Lets Tron Server read and edit files.")
                permissionRow(.screenRecording,
                              title: "Screen Recording",
                              detail: "Lets Tron Server see your screen.")
                permissionRow(.accessibility,
                              title: "Accessibility",
                              detail: "Lets Tron Server click and type for you.")
            }
            .padding(.vertical, 1)

            Button {
                Task { await refreshAll(showActivity: true) }
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
        detail: String
    ) -> some View {
        let status = state.permissionStatuses[permission] ?? .notDetermined
        let appName = permissionAppDisplayName
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
                    Text(instruction(for: permission, appName: appName))
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
                        ScreenRecordingAppShortcut(
                            appURL: setup.applicationBundle,
                            displayName: appName
                        )
                        .frame(
                            width: PermissionsStepLayout.appShortcutHitSize,
                            height: PermissionsStepLayout.appShortcutHitSize
                        )
                    }

                    Button {
                        openPermissionSettings(permission)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.wizardTertiary)
                    .help("Open Settings and enable \(appName)")
                    .accessibilityLabel("Open Settings for \(title) and enable \(appName)")
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

    private var permissionAppDisplayName: String {
        PermissionsStepContent.appDisplayName(for: setup.applicationBundle)
    }

    private func instruction(for permission: Permission, appName: String) -> String {
        switch permission {
        case .fullDiskAccess:
            return "Enable \"\(appName)\" in Full Disk Access."
        case .screenRecording:
            return "Drag the icon into the list if \"\(appName)\" is missing."
        case .accessibility:
            return "Enable \"\(appName)\" in Accessibility."
        }
    }

    /// Opens the relevant Settings pane without calling prompt APIs.
    /// macOS lists the wrapper automatically for the signed app builds
    /// we support; extra prompt dialogs add confusion because the pane
    /// is already visible.
    private func openPermissionSettings(_ permission: Permission) {
        settingsReturnPending = true
        startSettingsGrantWatch(for: permission)
        NSWorkspace.shared.open(PermissionDeepLink.url(for: permission))
    }

    // MARK: - Polling lifecycle

    /// Starts the 2 s agent-probe poll loop. Runs until the view
    /// disappears or all three grants are observed, whichever comes
    /// first. The loop is re-entrant — calling this twice is a no-op
    /// thanks to the `pollTask` guard.
    @MainActor
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

        await refreshAll(showActivity: false)

        guard pollTask == nil else { return }
        pollTask = Task { [weak state = self.state] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                if Task.isCancelled { break }
                let snapshot = await setup.probePermissions()
                await MainActor.run {
                    guard let state else { return }
                    Self.applyPermissionSnapshot(snapshot, to: state)
                }
                // Stop polling once everything is granted — no point
                // hammering the engine protocol when the user is still on this
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
    /// view. Both paths are fast probes; the only difference is whether
    /// the visible Re-check control briefly shows activity.
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
    /// Settings pane from this page. It does not restart the helper; it
    /// just performs quick non-prompting wrapper probes so the row flips
    /// green as soon as macOS reports the grant.
    @MainActor
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

                await refreshAll(showActivity: false)

                if state.permissionStatuses[permission] == .granted {
                    return
                }
            }
        }
    }

    /// One-shot wrapper probe. This is intentionally a probe only: no
    /// `launchctl kickstart`, no launchd polling loop, and no prompt.
    @MainActor
    private func refreshAll(showActivity: Bool) async {
        if showActivity {
            checkingPermissions = true
        }
        defer {
            if showActivity {
                checkingPermissions = false
            }
        }
        let snapshot = await setup.probePermissions()
        Self.applyPermissionSnapshot(snapshot, to: state)
    }

    /// Applies a probe snapshot while preserving the last concrete
    /// answer across transient engine protocol failures. If launchd is briefly
    /// cycling for some unrelated reason, an all-unknown probe snapshot should
    /// not wipe green/red badges into confusing gray icons.
    @MainActor
    private static func applyPermissionSnapshot(
        _ snapshot: [Permission: PermissionStatus],
        to state: WizardState
    ) {
        for permission in Permission.allCases {
            guard let status = snapshot[permission] else { continue }
            if status == .probeUnavailable,
               state.permissionStatuses[permission] != nil {
                continue
            }
            state.permissionStatuses[permission] = status
        }
    }

    /// Wrapper for the app-activation path. The pending Settings
    /// round-trip is consumed before awaiting so repeated activation
    /// notifications from the same System Settings visit cannot keep
    /// flipping the visible Re-check control into a busy state.
    @MainActor
    private func handleAppActivation() async {
        guard state.step == .permissions else { return }
        let showActivity = settingsReturnPending
        settingsReturnPending = false
        await refreshAll(showActivity: showActivity)
    }
}

private struct ScreenRecordingAppShortcut: NSViewRepresentable {
    let appURL: URL
    let displayName: String

    func makeNSView(context: Context) -> ScreenRecordingAppShortcutView {
        let view = ScreenRecordingAppShortcutView()
        view.configure(appURL: appURL, displayName: displayName)
        return view
    }

    func updateNSView(_ nsView: ScreenRecordingAppShortcutView, context: Context) {
        nsView.configure(appURL: appURL, displayName: displayName)
    }
}

private final class ScreenRecordingAppShortcutView: NSView, NSDraggingSource {
    private var appURL: URL?
    private var appIcon = NSImage.tronShortcutPlaceholderAppIcon
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: PermissionsStepLayout.appShortcutHitSize,
            height: PermissionsStepLayout.appShortcutHitSize
        )
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        true
    }

    func configure(appURL: URL, displayName: String) {
        self.appURL = appURL
        toolTip = "Drag \(displayName) into the Screen Recording list if it is missing."
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(displayName) Screen Recording shortcut")
        appIcon = Self.icon(for: appURL)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        NSShadow.screenRecordingShortcutShadow.set()
        appIcon.draw(in: iconDrawingRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let appURL,
              FileManager.default.fileExists(atPath: appURL.path) else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint, hypot(point.x - start.x, point.y - start.y) < 3 {
            return
        }

        didStartDrag = true
        let item = NSDraggingItem(pasteboardWriter: Self.dragPasteboardItem(for: appURL))
        item.setDraggingFrame(iconDrawingRect, contents: appIcon)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        didStartDrag = false
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
        mouseDownPoint = nil
        didStartDrag = false
    }

    private static func dragPasteboardItem(for appURL: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(appURL.absoluteString, forType: .fileURL)
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
        return .tronShortcutPlaceholderAppIcon
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
    static var tronShortcutPlaceholderAppIcon: NSImage {
        NSImage(named: "AppIcon")
            ?? NSImage(size: NSSize(
                width: PermissionsStepLayout.appShortcutIconSize,
                height: PermissionsStepLayout.appShortcutIconSize
            ))
    }
}

private extension NSShadow {
    static var screenRecordingShortcutShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 8
        return shadow
    }
}

enum PermissionsStepContent {
    static let intro = "Enable the Tron app named on each row in System Settings."
    static let initialProbeDelayNanoseconds: UInt64 = 520_000_000
    static let settingsGrantWatchAttempts = 24
    static let settingsGrantWatchIntervalNanoseconds: UInt64 = 750_000_000

    static func appDisplayName(for applicationBundle: URL) -> String {
        let name = applicationBundle.lastPathComponent
        return name.isEmpty ? "Tron.app" : name
    }
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
