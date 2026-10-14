import SwiftUI
import TronMobileCore

/// Mac Terminal (Settings › Accounts): a login shell on the paired Mac over
/// Tailscale through macOS Remote Login, in the session terminal's chrome and
/// emulator. Only enabling and removing it use the Gateway; the shell itself
/// connects straight to the Mac, so it works while Tron.app or the Gateway is
/// quit, crashed or being replaced.
struct MacTerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = MacTerminalController()
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmRemove = false
    @State private var removalError: String?

    var body: some View {
        TerminalSheetChrome(title: "Mac Terminal", phase: controller.phase, keyboard: keyboard) { accent in
            content(accent: accent)
        } menu: {
            menu
        }
        .task { controller.start(model: model) }
        .onDisappear { controller.close() }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app's sockets in the background; back in the
            // foreground a dropped connection opens a new shell by itself.
            guard phase == .active, case .ended = controller.stage else { return }
            controller.reconnect()
        }
        .alert("Remove Mac Terminal?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    do { try await controller.removeKey(model: model) }
                    catch { removalError = error.localizedDescription }
                }
            }
        } message: {
            Text("This iPhone's key is removed from ~/.ssh/authorized_keys on the Mac and deleted here. You can enable Mac Terminal again while the Gateway is running.")
        }
        .tronManagedSystemPresentation(isPresented: $confirmRemove, identity: "mac-terminal.remove-confirmation")
        .alert("Mac Terminal", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }

    @ViewBuilder
    private func content(accent: Color) -> some View {
        switch controller.stage {
        case .loading:
            TronSheetLoadingState(label: "Checking your Mac…", accent: accent)
        case .enrolling:
            TronSheetLoadingState(label: "Adding this iPhone's key…", accent: accent)
        case .connecting:
            TronSheetLoadingState(label: "Connecting to your Mac…", accent: accent)
        case .setup(let notice):
            placeholder(setup(notice), accent: accent)
        case .failed(let message):
            placeholder(Placeholder(title: "Mac Terminal unavailable", detail: message, actionTitle: "Try Again") {
                if controller.enrollment != nil { controller.reconnect() } else { Task { await controller.refreshSetup(model: model) } }
            }, accent: accent)
        case .connected, .ended:
            TerminalSurface(
                chunks: controller.chunks,
                isInteractive: controller.isRunning,
                keyboard: keyboard,
                onSend: { controller.send($0) },
                onResize: { controller.resize(columns: $0, rows: $1) }
            )
            .id(controller.connectionGeneration)
        }
    }

    private struct Placeholder {
        var icon = "terminal"
        let title: String
        let detail: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private func placeholder(_ placeholder: Placeholder, accent: Color) -> some View {
        ScrollView {
            TronPlaceholderState(title: placeholder.title, detail: placeholder.detail, icon: placeholder.icon,
                                 accent: accent, actionTitle: placeholder.actionTitle, action: placeholder.action)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .accessibilityIdentifier("mac-terminal-placeholder")
    }

    private func setup(_ notice: MacTerminalController.SetupNotice) -> Placeholder {
        switch notice {
        case .ready(let username):
            Placeholder(
                title: "Open a shell on your Mac",
                detail: "Mac Terminal signs in as \(username) with a key that stays in this iPhone's Secure Enclave. It connects over Tailscale through Remote Login, so it works even when Tron on the Mac is not running. Enabling it adds this iPhone's key to ~/.ssh/authorized_keys, for Tailscale addresses only.",
                actionTitle: "Enable Mac Terminal"
            ) { Task { await controller.enroll(model: model) } }
        case .remoteLoginOff:
            Placeholder(
                icon: "lock.shield",
                title: "Turn on Remote Login",
                detail: "On the Mac, open System Settings › General › Sharing and turn on Remote Login. Tron never changes this setting for you.",
                actionTitle: "Check Again"
            ) { Task { await controller.refreshSetup(model: model) } }
        case .needsGateway:
            Placeholder(
                icon: "desktopcomputer.trianglebadge.exclamationmark",
                title: "Connect to your Mac first",
                detail: "Enabling Mac Terminal adds this iPhone's key on the Mac through Tron. Once it is enabled, Mac Terminal works without the Gateway.",
                actionTitle: "Check Again"
            ) { Task { await controller.refreshSetup(model: model) } }
        case .macNotOnTailnet:
            Placeholder(
                icon: "network.slash",
                title: "The Mac is not on Tailscale",
                detail: "Mac Terminal connects over your tailnet. Open Tailscale on the Mac, sign in to the same tailnet as this iPhone, then check again.",
                actionTitle: "Check Again"
            ) { Task { await controller.refreshSetup(model: model) } }
        case .unpaired:
            Placeholder(
                icon: "iphone.slash",
                title: "Pair this iPhone with a Mac",
                detail: "Mac Terminal needs a paired Mac. Pair one in Settings › Connections."
            )
        }
    }

    @ViewBuilder
    private var menu: some View {
        if controller.enrollment != nil {
            Button(controller.isRunning ? "New Shell" : "Reconnect", systemImage: "arrow.clockwise") {
                controller.reconnect()
            }
            if let endpoint = controller.enrollment?.endpoint {
                Section("\(endpoint.username) on \(endpoint.hosts.first ?? "your Mac")") {}
            }
            Button("Remove Mac Terminal", systemImage: "key.slash", role: .destructive) { confirmRemove = true }
        } else {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await controller.refreshSetup(model: model) }
            }
        }
    }
}
