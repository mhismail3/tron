import MacTerminalSSH
import SwiftUI
import TronMobileCore

/// The Settings › Tools & Diagnostics row. Mac Terminal is the terminal sheet itself,
/// presented directly like Manage Session's terminal, not wrapped in a
/// settings destination's navigation stack and Done.
struct MacTerminalSettingsRow: View {
    @State private var isPresented = false
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
                .tronSettingsVisualTheme(accent: theme?.accent ?? .tronEmerald)
                .tronPresentation()
        }
    }
}

/// Mac Terminal (Settings › Tools & Diagnostics): login shells on the paired
/// Mac over Tailscale through macOS Remote Login, in the session terminal's
/// chrome and emulator. Only enabling and removing it use the Gateway; the
/// shells live in the Mac's shell host, so they keep running when this sheet
/// closes or the app leaves the foreground, and while Tron.app or the Gateway
/// is quit, crashed or being replaced (#1075). The controller is app-scoped
/// (`AppModel.macTerminal`); this sheet only presents it.
struct MacTerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmRemove = false
    @State private var confirmQuit = false
    @State private var removalError: String?

    private var controller: MacTerminalController { model.macTerminal }

    var body: some View {
        TerminalSheetChrome(title: "Mac Terminal", phase: controller.phase, keyboard: keyboard) { accent in
            content(accent: accent)
                // A second alert on the chrome would collide with the
                // confirmation's; this one hangs off the content instead.
                .alert("Mac Terminal", isPresented: removalErrorPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(removalError ?? "")
                }
                .tronManagedSystemPresentation(isPresented: removalErrorPresented, identity: "mac-terminal.remove-error")
                .alert("Quit Shell?", isPresented: $confirmQuit) {
                    Button("Cancel", role: .cancel) {}
                    Button("Quit Shell", role: .destructive) { controller.quit() }
                } message: {
                    Text("The shell and its running programs stop. Closing Mac Terminal alone keeps the shell running on your Mac.")
                }
                .tronManagedSystemPresentation(isPresented: $confirmQuit, identity: "mac-terminal.quit-confirmation")
        } menu: {
            menu
        }
        .task { controller.present(model: model) }
        .onDisappear { controller.conceal() }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the app's sockets in the background. The shell stays
            // on the Mac; the link closes here and reattaches on return.
            switch phase {
            case .active: controller.present(model: model)
            case .background: controller.conceal()
            default: break
            }
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
            Text("This iPhone's key is removed from ~/.ssh/authorized_keys on the Mac and deleted here. Shells already open on the Mac keep running until they exit. You can enable Mac Terminal again while the Gateway is running.")
        }
        .tronManagedSystemPresentation(isPresented: $confirmRemove, identity: "mac-terminal.remove-confirmation")
    }

    private var removalErrorPresented: Binding<Bool> {
        Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })
    }

    @ViewBuilder
    private func content(accent: Color) -> some View {
        switch controller.stage {
        case .loading:
            TronSheetLoadingState(label: "Checking your Mac…", accent: accent)
        case .enrolling:
            TronSheetLoadingState(label: "Adding this iPhone's key…", accent: accent)
        case .setup(let notice):
            placeholder(setup(notice), accent: accent)
        case .failed(let message):
            placeholder(Placeholder(title: "Mac Terminal unavailable", detail: message, actionTitle: "Try Again") {
                if controller.enrollment != nil { controller.reconnect() } else { Task { await controller.refreshSetup(model: model) } }
            }, accent: accent)
        case .terminal:
            if controller.chunks.isEmpty && controller.link != .idle {
                TronSheetLoadingState(label: "Connecting to your Mac…", accent: accent)
            } else {
                TerminalSurface(
                    chunks: controller.chunks,
                    isInteractive: controller.isRunning,
                    keyboard: keyboard,
                    onSend: { controller.send($0) },
                    onResize: { controller.resize(columns: $0, rows: $1) }
                )
                .id(controller.rendererGeneration)
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
        case .noHostKeys:
            Placeholder(
                icon: "lock.trianglebadge.exclamationmark",
                title: "The Mac has no SSH host key",
                detail: "Mac Terminal pins the Mac's host key so it can never connect to an impostor, and the Mac reported none in /etc/ssh. Turn Remote Login off and on again on the Mac, then check again.",
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

    /// The session terminal's menu shape (TerminalSheet): a new-shell action,
    /// Open and Recent sections with the Gateway's closure reason as a Recent
    /// item's subtitle (#479), then Quit. Shells are numbered in the order the
    /// Mac opened them.
    @ViewBuilder
    private var menu: some View {
        if controller.enrollment != nil {
            Button("New Shell", systemImage: "plus") { controller.newShell() }
            if controller.mode == .host {
                if !controller.liveShells.isEmpty {
                    Section("Open shells") {
                        ForEach(controller.liveShells) { shell in
                            shellItem(shell, detail: "Started \(Self.time(shell.createdAt))")
                        }
                    }
                }
                if !controller.exitedShells.isEmpty {
                    Section("Recent shells") {
                        ForEach(controller.exitedShells) { shell in
                            shellItem(shell, detail: shell.closedReason
                                ?? "Exited \(shell.exitedAt.map(Self.time) ?? "")\(shell.exitCode.map { " with status \($0)" } ?? "")")
                        }
                    }
                }
            }
            if controller.link == .idle {
                Button("Reconnect", systemImage: "arrow.clockwise") { controller.reconnect() }
            }
            Button("Quit Shell", systemImage: "xmark.octagon", role: .destructive) { confirmQuit = true }
                .disabled(!controller.isRunning)
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

    private func shellItem(_ shell: MacShell, detail: String) -> some View {
        let title = "Shell \((controller.shells.firstIndex(of: shell) ?? 0) + 1)"
        let selected = shell.id == controller.selectedShellID
        return Button {
            controller.select(shell)
        } label: {
            // A menu item's second text is its subtitle.
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
            Text(detail)
        }
        .accessibilityLabel([title, detail, selected ? "current" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("mac-terminal-shell-\(title)")
    }

    private static func time(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
