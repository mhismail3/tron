import SwiftTerm
import SwiftUI
import UIKit
import TronMobileCore

/// Manage Session and Manage Home share the same launch affordance and shell owner.
struct SessionTerminalToolbarButton: View {
    let enabled: Bool
    let identifier: String
    /// The presenting sheet's title tint.
    var accent: SwiftUI.Color = .tronEmerald
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "terminal")
                .font(TronTypography.buttonSM)
                .tronToolbarAction(accent: accent)
        }
        .disabled(!enabled)
        .accessibilityLabel("Terminal")
        .accessibilityIdentifier(identifier)
    }
}

struct TerminalSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @State private var controller = TerminalController()
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmQuit = false

    var body: some View {
        TerminalSheetChrome(title: "Terminal", phase: controller.connectionPhase, keyboard: keyboard) { accent in
            if let error = controller.error, controller.terminal == nil {
                ScrollView {
                    TronPlaceholderState(title: "Terminal unavailable", detail: error,
                                         icon: "terminal", accent: accent)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
            } else if let terminal = controller.terminal {
                let replay = model.terminalReplay(for: terminal.id)
                TerminalSurface(
                    chunks: replay.chunks,
                    isInteractive: controller.isRunning(model: model),
                    keyboard: keyboard,
                    onSend: { controller.send($0, model: model) },
                    onResize: { controller.resize(columns: $0, rows: $1, model: model) }
                )
                .id(TerminalRendererIdentity(
                    terminalID: terminal.id,
                    replayRevision: replay.revision
                ))
            } else {
                TronSheetLoadingState(label: "Connecting terminal…", accent: accent)
            }
        } menu: {
            terminalMenu
        }
        .task {
            controller.start(sessionID: sessionID, model: model)
        }
        .onDisappear { controller.stop(model: model) }
        .alert("Quit Terminal?", isPresented: $confirmQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Quit Terminal", role: .destructive) { controller.terminate(model: model) }
        } message: {
            Text("The shell and its running process group will stop. Closing the sheet alone only detaches.")
        }
        .tronManagedSystemPresentation(
            isPresented: $confirmQuit,
            identity: "terminal.quit-confirmation"
        )
    }

    private var openTerminals: [TerminalSummary] {
        controller.history.filter { $0.exitedAt == nil && !model.terminalHasExited($0.id) }
    }

    private var recentTerminals: [TerminalSummary] {
        controller.history.filter { $0.exitedAt != nil || model.terminalHasExited($0.id) }
    }

    @ViewBuilder
    private var terminalMenu: some View {
            if !controller.isRunning(model: model) {
                Button("Open Live Terminal", systemImage: "terminal") {
                    controller.openLive(model: model)
                }
            }
            if !openTerminals.isEmpty {
                Section("Open terminals") {
                    ForEach(openTerminals) { terminal in
                        Button {
                            controller.show(terminal, model: model)
                        } label: {
                            Text(terminal.createdAt)
                        }
                    }
                }
            }
            if !recentTerminals.isEmpty {
                Section("Recent terminals") {
                    ForEach(recentTerminals) { terminal in
                        Button {
                            controller.show(terminal, model: model)
                        } label: {
                            // A menu item's second text is its subtitle: why the
                            // Gateway closed it, when it did (#479).
                            Text(terminal.exitedAt ?? terminal.createdAt)
                            if let reason = terminal.closedReason { Text(reason) }
                        }
                        .accessibilityLabel([terminal.exitedAt ?? terminal.createdAt, terminal.closedReason]
                            .compactMap { $0 }.joined(separator: ", "))
                    }
                }
            }
            Button("Quit Terminal", role: .destructive) { confirmQuit = true }
                .disabled(!controller.isRunning(model: model))
    }
}

/// The one terminal sheet chrome: the session terminal (Manage Session and
/// Manage Home) and Mac Terminal (Settings) share its title with the phase dot,
/// options menu, Done button, top blur and detents, so the two read as one
/// component. Content supplies the emulator or a placeholder.
struct TerminalSheetChrome<Content: View, MenuContent: View>: View {
    let title: String
    let phase: TerminalConnectionPhase
    let keyboard: TerminalKeyboardController
    @ViewBuilder let content: (SwiftUI.Color) -> Content
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var accent: SwiftUI.Color { settingsTheme?.accent ?? .tronEmerald }

    var body: some View {
        NavigationStack {
            Group { content(accent) }
                .tronTopBlurSurface()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu { menu() } label: {
                            Image(systemName: "ellipsis")
                                .font(TronTypography.buttonSM)
                                .tronToolbarAction()
                        }
                        .accessibilityLabel("\(title) options")
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 7) {
                            Circle().fill(phase.color).frame(width: 7, height: 7)
                            Text(title)
                                .font(TronTypography.button)
                                .foregroundStyle(accent)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                        .accessibilityValue(phase.label)
                        .accessibilityIdentifier("terminal-sheet-title")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .tronToolbarAction()
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
        .animation(.easeOut(duration: 0.16), value: keyboard.isKeyboardPresented)
    }
}

/// The emulator with the session terminal's padding and keyboard control bar.
struct TerminalSurface: View {
    let chunks: [TerminalChunk]
    let isInteractive: Bool
    let keyboard: TerminalKeyboardController
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    var body: some View {
        NativeTerminal(
            chunks: chunks,
            isInteractive: isInteractive,
            keyboard: keyboard,
            onSend: onSend,
            onResize: onResize
        )
        .padding(.horizontal, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboard.isKeyboardPresented {
                TerminalControlBar(keyboard: keyboard)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
