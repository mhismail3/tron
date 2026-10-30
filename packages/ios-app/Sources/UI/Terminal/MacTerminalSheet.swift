import MacTerminalSSH
import SwiftUI
import TronMobileCore

/// The Settings › System row. Mac Terminal is the terminal sheet itself,
/// presented directly like Manage Session's terminal, not wrapped in a
/// settings destination's navigation stack and Done.
struct MacTerminalSettingsRow: View {
    @PresentationState private var isPresented = false
    @Environment(\.tronSettingsVisualTheme) private var theme

    var body: some View {
        Button { isPresented = true } label: {
            TronSettingsRow(icon: "apple.terminal", title: "Mac Terminal",
                            subtitle: "A shell on your Mac, even without the Gateway", subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac Terminal")
        .accessibilityIdentifier("settings-link-Mac Terminal")
        .tronManagedSheet(isPresented: $isPresented, identity: "settings.Mac Terminal") {
            MacTerminalSheet()
                .tronSettingsVisualTheme(accent: theme?.accent ?? .tronPrimary)
                .tronPresentation()
        }
    }
}

/// Mac Terminal (Settings › System): login shells on the paired
/// Mac over the private user SSH service on Tailscale, in the session terminal's
/// chrome and emulator. Only enabling and removing it use the Gateway; the
/// shell lives in tmux, so it keeps running when this sheet
/// closes or the app leaves the foreground, and while Tron.app or the Gateway
/// is quit, crashed or being replaced (#1075). The controller is app-scoped
/// (`AppModel.macTerminal`); this sheet only presents it.
struct MacTerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    // Presentation-scoped (#1073): SwiftUI rebuilds this content when the app
    // returns from the background while the sheet stays presented; the keyboard,
    // emulator and alerts belong to the presentation, not the view. The shells
    // and their output belong to the app-scoped controller (#1075).
    @PresentationState private var keyboard = TerminalKeyboardController()
    @PresentationState private var emulator = TerminalEmulatorHost()
    @PresentationState private var confirmRemove = false
    @PresentationState private var removalError: String?

    private var controller: MacTerminalController { model.macTerminal }

    var body: some View {
        TerminalSheetChrome(title: "Mac Terminal", phase: controller.phase, keyboard: keyboard) { accent in
            content(accent: accent)
                .tronConfirmation("Mac Terminal", isPresented: removalErrorPresented, cancelTitle: "OK") {
                    EmptyView()
                } message: {
                    Text(removalError ?? "")
                }
        } menu: {
            menu
        }
        // Idempotent: a rebuilt sheet finds its link already open. Dismissal
        // (not a rebuild, #1073) only detaches; the shell stays on the Mac.
        .task { controller.present(model: model) }
        .onPresentationRetire { controller.conceal() }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app's sockets in the background. The shell stays
            // on the Mac; the link closes here and reattaches on return.
            switch phase {
            case .active: controller.present(model: model)
            case .background: controller.conceal()
            default: break
            }
        }
        .tronConfirmation("Remove Mac Terminal?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    do { try await controller.removeKey(model: model) }
                    catch { removalError = error.localizedDescription }
                }
            }
        } message: {
            Text("This iPhone's key is removed from the private SSH service on the Mac and deleted here. Shells already open on the Mac keep running until they exit. You can enable Mac Terminal again while the Gateway is running.")
        }
    }

    private var removalErrorPresented: Binding<Bool> {
        Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })
    }

    @ViewBuilder
    private func content(accent: Color) -> some View {
        switch controller.stage {
        case .loading:
            TronSheetLoadingState(label: "Checking your Mac…", accent: accent)
        case .preparing:
            TronSheetLoadingState(label: "Preparing private SSH…", accent: accent)
        case .trust(let status):
            ScrollView {
                VStack(spacing: 20) {
                    TronPlaceholderState(title: "Trust this Mac’s private SSH identity?",
                        detail: "\(status.username) at \(status.hosts.first ?? "your Mac"):\(status.port). Verify the fingerprint on the Mac. Your previous enrollment stays unchanged until you trust it.",
                        icon: "lock.shield", accent: accent)
                    Text(status.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("mac-terminal-host-fingerprint")
                    Button("Trust and Enroll") { Task { await controller.trustHost(model: model) } }
                        .buttonStyle(.borderedProminent).tint(accent)
                    Button("Decline", role: .cancel) { controller.declineHost() }
                }.padding()
            }
        case .enrolling:
            TronSheetLoadingState(label: "Adding this iPhone's key…", accent: accent)
        case .setup(let notice):
            placeholder(setup(notice), accent: accent)
        case .failed(let message):
            placeholder(Placeholder(title: "Mac Terminal unavailable", detail: message, actionTitle: "Try Again") {
                if controller.enrollment != nil { controller.reconnect() } else { Task { await controller.refreshSetup(model: model) } }
            }, accent: accent)
        case .terminal:
            if controller.chunks.isEmpty && controller.link == .connecting {
                TronSheetLoadingState(label: "Connecting to your Mac…", accent: accent)
            } else {
                // One emulator per shell view for the presentation: switching
                // attachment gets a fresh one.
                let identity = controller.rendererGeneration
                TerminalSurface(
                    chunks: controller.chunks,
                    isInteractive: controller.isRunning,
                    keyboard: keyboard,
                    emulator: emulator,
                    emulatorIdentity: identity,
                    onSend: { controller.send($0) },
                    onResize: { controller.resize(columns: $0, rows: $1) }
                )
                .id(identity)
            }
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
                detail: "Mac Terminal signs in as \(username) through Tron’s private user SSH server, bound only to the Mac’s Tailscale IPv4. It works without the Gateway and does not change Remote Login. Enable prepares its identity; only Trust and Enroll publishes this iPhone’s Secure Enclave key.",
                actionTitle: "Enable Mac Terminal"
            ) { Task { await controller.enroll(model: model) } }
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
        case .serviceIssue(let message):
            Placeholder(icon: "lock.trianglebadge.exclamationmark", title: "Private SSH needs attention",
                detail: message, actionTitle: "Check Again") { Task { await controller.refreshSetup(model: model) } }
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
        if let endpoint = controller.enrollment?.endpoint {
            Button("Reconnect", systemImage: "arrow.clockwise") { controller.reconnect() }
                .disabled(controller.isChangingAuthorization)
            Button("Refresh SSH Enrollment", systemImage: "key") { Task { await controller.refreshSetup(model: model) } }
                .disabled(controller.isChangingAuthorization || model.connectionState != .connected)
            Section("\(endpoint.username) on \(endpoint.hosts.first ?? "your Mac")") {}
            Button("Remove Mac Terminal", systemImage: "key.slash", role: .destructive) { confirmRemove = true }
                .disabled(controller.isChangingAuthorization)
        } else {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await controller.refreshSetup(model: model) }
            }
        }
    }
}
