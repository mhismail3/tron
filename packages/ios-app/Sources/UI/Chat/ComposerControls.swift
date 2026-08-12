import SwiftUI

/// Historical session-owned context indicator. Its value is projected from the
/// canonical snapshot and tapping it opens Manage Session; it owns no runtime
/// state or mutation path.
struct SessionContextProgressButton: View {
    let contextPercentage: Int
    let modelName: String?
    let isCompacting: Bool
    let onTap: () -> Void

    private var boundedPercentage: Int { min(max(contextPercentage, 0), 100) }
    private var fraction: Double { Double(boundedPercentage) / 100 }
    private var accent: Color {
        switch boundedPercentage {
        case 95...: .tronError
        case 80...: .tronAmber
        default: .tronEmerald
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(Color.tronTextMuted.opacity(0.34), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if isCompacting {
                    Circle().fill(accent).frame(width: 4, height: 4)
                }
            }
            .frame(width: 15, height: 15)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-context-button")
        .accessibilityLabel("Manage Session")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows context usage, model selection, and session actions")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: fraction)
    }

    private var accessibilityValue: String {
        var values = modelName.map { [$0] } ?? []
        values.append("\(boundedPercentage)% context used")
        if isCompacting { values.append("compacting") }
        return values.joined(separator: ", ")
    }
}

enum ComposerTrailingMode: Equatable {
    case stopAgent
    case stopRecording
    case send
    case record
}

struct ComposerTrailingButton: View {
    let mode: ComposerTrailingMode
    let isDisabled: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent, .stopRecording:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronError)
                case .send:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                case .record:
                    Image(systemName: "mic.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && mode == .send)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch mode {
        case .stopAgent: "Stop Tron"
        case .stopRecording: "Stop recording"
        case .send: "Send message"
        case .record: "Record voice input"
        }
    }

    private func performAction() {
        switch mode {
        case .stopAgent: onAbort()
        case .stopRecording, .record: onMicTap()
        case .send: onSend()
        }
    }
}
