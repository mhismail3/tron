import SwiftUI

enum ComposerControlMetrics {
    static let hitTarget: CGFloat = 40
    static let symbolSize: CGFloat = 16
    static let contextRingDiameter: CGFloat = 16
}

struct SessionContextProgressPresentation: Equatable {
    let contextPercentage: Int
    let modelName: String?
    let isCompacting: Bool
    let isEnabled: Bool
}

enum SessionContextProgressPolicy {
    static func presentation(
        isTranscriptReady: Bool,
        contextPercentage: Int?,
        modelName: String?,
        isCompacting: Bool
    ) -> SessionContextProgressPresentation {
        guard isTranscriptReady, let contextPercentage else {
            return SessionContextProgressPresentation(
                contextPercentage: 0,
                modelName: nil,
                isCompacting: false,
                isEnabled: false
            )
        }
        return SessionContextProgressPresentation(
            contextPercentage: contextPercentage,
            modelName: modelName,
            isCompacting: isCompacting,
            isEnabled: true
        )
    }
}

/// Historical session-owned context indicator. It remains mounted at zero
/// while the authoritative chat opens, then animates to the canonical value.
/// Tapping it opens Manage Session; it owns no runtime state or mutation path.
struct SessionContextProgressButton: View {
    let presentation: SessionContextProgressPresentation
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contextPercentage: Int { presentation.contextPercentage }
    private var modelName: String? { presentation.modelName }
    private var isCompacting: Bool { presentation.isCompacting }

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
            .frame(
                width: ComposerControlMetrics.contextRingDiameter,
                height: ComposerControlMetrics.contextRingDiameter
            )
            .frame(
                width: ComposerControlMetrics.hitTarget,
                height: ComposerControlMetrics.hitTarget
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .opacity(presentation.isEnabled ? 1 : 0.56)
        .accessibilityIdentifier("session-context-button")
        .accessibilityLabel("Manage Session")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows context usage, model selection, and session actions")
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: fraction
        )
    }

    private var accessibilityValue: String {
        guard presentation.isEnabled else { return "Session context loading" }
        var values = modelName.map { [$0] } ?? []
        values.append("\(boundedPercentage)% context used")
        if isCompacting { values.append("compacting") }
        return values.joined(separator: ", ")
    }
}

enum ComposerTrailingMode: Equatable {
    case stopAgent
    case send
}

enum ChatComposerPolicy {
    static func isTextEditable(isTranscriptReady: Bool) -> Bool {
        // Drafting is local and remains available while authoritative opening
        // finishes; send and attachment mutations retain their own readiness gates.
        true
    }

    static func trailingMode(
        phase: SessionPhase?,
        hasContent: Bool,
        isSending: Bool = false
    ) -> ComposerTrailingMode? {
        if isSending || hasContent { return .send }
        if phase?.isActive == true { return .stopAgent }
        return nil
    }

    static func submissionBehavior(phase: SessionPhase?) -> String? {
        phase?.isActive == true ? "steer" : nil
    }

    static func preservesFocus(submissionBehavior: String?) -> Bool {
        false
    }

    static func abortKind(operation: SessionOperationState?) -> String {
        switch operation?.kind {
        case .compaction: "compaction"
        case .branchSummary: "branchSummary"
        case .bash: "bash"
        case .retry: "retry"
        case .prompt, .command, .none: "agent"
        }
    }

    static func restoredDraft(outgoing: String, currentDraft: String) -> String {
        ComposerDraftTextPolicy.restoredDraft(
            outgoing: outgoing,
            currentDraft: currentDraft
        )
    }
}

struct ComposerTrailingButtonPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.22, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

struct ComposerTrailingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: ComposerTrailingMode
    let isDisabled: Bool
    let isSending: Bool
    let offersQueueChoices: Bool
    let onSend: (String?) -> Void
    let onAbort: () -> Void

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.sans(
                            size: ComposerControlMetrics.symbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.tronError)
                case .send:
                    ZStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(TronTypography.sans(
                                size: ComposerControlMetrics.symbolSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                            .opacity(isSending ? 0 : 1)
                            .scaleEffect(isSending && !reduceMotion ? 0.72 : 1)
                        if isSending {
                            TronPulseLoadingIndicator(accent: .tronEmerald, size: 18)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .scale(scale: 0.72).combined(with: .opacity)
                                )
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSending)
                }
            }
            .frame(
                width: ComposerControlMetrics.hitTarget,
                height: ComposerControlMetrics.hitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerTrailingButtonPressStyle())
        .disabled(isDisabled && mode == .send)
        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .contextMenu {
            if mode == .send, offersQueueChoices, !isSending {
                Button("Steer after current turn", systemImage: "arrow.turn.up.right") {
                    onSend("steer")
                }
                Button("Follow up after current work", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    onSend("followUp")
                }
            }
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .stopAgent: "Stop Tron"
        case .send: isSending ? "Sending message" : "Send message"
        }
    }

    private var accessibilityHint: String {
        if isSending { return "Waiting for the message to be admitted." }
        if mode == .send, offersQueueChoices {
            return "Sends steering after the current turn. Touch and hold to choose follow-up delivery."
        }
        return ""
    }

    private func performAction() {
        switch mode {
        case .stopAgent: onAbort()
        case .send: onSend(nil)
        }
    }
}
