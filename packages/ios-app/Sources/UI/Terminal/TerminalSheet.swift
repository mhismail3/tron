import SwiftTerm
import SwiftUI
import UIKit
import TronMobileCore

enum TerminalConnectionPhase: Equatable {
    case connecting, connected, unavailable, notConnected

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .unavailable: "Unavailable"
        case .notConnected: "Not connected"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .connected: .tronEmerald
        case .connecting: .tronAmber
        case .unavailable: .tronError
        case .notConnected: .tronTextSecondary
        }
    }
}

/// Mac Terminal's title, connection phase, menu, Done and emulator surface.
struct TerminalSheetChrome<Content: View, MenuContent: View>: View {
    let title: String
    let phase: TerminalConnectionPhase
    let keyboard: TerminalKeyboardController
    @ViewBuilder let content: (SwiftUI.Color) -> Content
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var accent: SwiftUI.Color { settingsTheme?.accent ?? .tronPrimary }

    var body: some View {
        NavigationStack {
            Group { content(accent) }
                // A loading state is a zero-size pulse request: fill the sheet so
                // the top blur spans the surface, not a band at its middle.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The emulator with its padding and keyboard control bar.
struct TerminalSurface: View {
    let chunks: [TerminalChunk]
    let isInteractive: Bool
    let keyboard: TerminalKeyboardController
    let emulator: TerminalEmulatorHost
    let emulatorIdentity: AnyHashable
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    var body: some View {
        NativeTerminal(
            chunks: chunks,
            isInteractive: isInteractive,
            keyboard: keyboard,
            emulator: emulator,
            emulatorIdentity: emulatorIdentity,
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
