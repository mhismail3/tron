import SwiftUI

// MARK: - Context Briefing Button

/// Compact context-window progress control that opens Session Briefing.
///
/// The full ring is the model's available context and the colored arc is the
/// server-projected percentage currently in use. Model identity remains in the
/// accessibility value instead of occupying a separate visual pill. The ring
/// is intentionally background-free because the enclosing composer owns the
/// Liquid Glass surface.
struct ContextBriefingButton: View {
    let contextPercentage: Int
    var modelName: String?
    var onTap: (() -> Void)? = nil

    private let ringSize: CGFloat = 17

    static func boundedPercentage(for percentage: Int) -> Int {
        min(max(percentage, 0), 100)
    }

    static func progressFraction(for percentage: Int) -> Double {
        Double(boundedPercentage(for: percentage)) / 100
    }

    private var canOpen: Bool {
        onTap != nil
    }

    private var progressFraction: Double {
        Self.progressFraction(for: contextPercentage)
    }

    private var boundedPercentage: Int {
        Self.boundedPercentage(for: contextPercentage)
    }

    private var accessibilityValue: String {
        let usage = "\(boundedPercentage)% context used"
        guard let modelName, !modelName.isEmpty else { return usage }
        return "\(modelName), \(usage)"
    }

    private var contextColor: Color {
        if boundedPercentage >= 95 {
            return .tronError
        } else if boundedPercentage >= 80 {
            return .tronAmber
        }
        return .tronEmerald
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            contextRing
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityIdentifier("session-briefing-button")
        .accessibilityLabel("Session Briefing")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(canOpen ? "Opens context and model controls" : "")
    }

    private var contextRing: some View {
        ZStack {
            Circle()
                .stroke(Color.tronTextMuted.opacity(0.34), lineWidth: 2)

            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(
                    contextColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ringSize, height: ringSize)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progressFraction)
        .accessibilityHidden(true)
    }
}
