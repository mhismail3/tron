import SwiftTerm
import SwiftUI
import UIKit

struct TerminalSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var controller = TerminalController()
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmQuit = false

    var body: some View {
        NavigationStack {
            Group {
                if let error = controller.error, controller.terminal == nil {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(error))
                } else if let terminal = controller.terminal {
                    let replay = model.terminalReplay(for: terminal.id)
                    NativeTerminal(
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
                    .padding(.horizontal, 8)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if keyboard.isKeyboardPresented {
                            TerminalControlBar(keyboard: keyboard)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                } else {
                    TronLoadingState(label: "Connecting terminal…")
                }
            }
            .background(Color.tronBackground)
            .tronTopBlurSurface()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { terminalMenu }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Circle().fill(controller.connectionPhase.color).frame(width: 7, height: 7)
                        Text("Terminal")
                            .font(TronTypography.button)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Terminal")
                    .accessibilityValue(controller.connectionPhase.label)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
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
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
        .animation(.easeOut(duration: 0.16), value: keyboard.isKeyboardPresented)
    }

    private var openTerminals: [TerminalSummary] {
        controller.history.filter { $0.exitedAt == nil && !model.terminalHasExited($0.id) }
    }

    private var recentTerminals: [TerminalSummary] {
        controller.history.filter { $0.exitedAt != nil || model.terminalHasExited($0.id) }
    }

    private var terminalMenu: some View {
        Menu {
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
                            Text(terminal.exitedAt ?? terminal.createdAt)
                        }
                    }
                }
            }
            Button("Quit Terminal", role: .destructive) { confirmQuit = true }
                .disabled(!controller.isRunning(model: model))
        } label: {
            Image(systemName: "ellipsis")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
        }
        .accessibilityLabel("Terminal options")
    }
}
