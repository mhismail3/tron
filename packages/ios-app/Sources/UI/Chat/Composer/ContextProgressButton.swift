import SwiftUI

/// Compact, session-owned context-window indicator.
///
/// The ring is presentation only: its percentage comes from the server's turn
/// token record and the selected model's advertised context window. Tapping it
/// opens the minimal Session Context sheet; it does not introduce a parallel
/// context-control service or authority path.
struct ContextProgressButton: View {
    let contextPercentage: Int
    let modelName: String?
    let isCompacting: Bool
    let onTap: () -> Void

    private let ringSize: CGFloat = 15

    private var boundedPercentage: Int {
        SessionContextPresentation.boundedPercentage(contextPercentage)
    }

    private var progressFraction: Double {
        SessionContextPresentation.progressFraction(contextPercentage)
    }

    private var accent: Color {
        SessionContextPresentation.pressure(for: contextPercentage).color
    }

    private var accessibilityValue: String {
        var components: [String] = []
        if let modelName, !modelName.isEmpty {
            components.append(modelName)
        }
        components.append("\(boundedPercentage)% context used")
        if isCompacting {
            components.append("compacting")
        }
        return components.joined(separator: ", ")
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(Color.tronTextMuted.opacity(0.34), lineWidth: 2)

                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                if isCompacting {
                    Circle()
                        .fill(accent)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-context-button")
        .accessibilityLabel("Session Context")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows context usage, model selection, and session actions")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progressFraction)
    }
}
