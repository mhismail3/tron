import SwiftUI

extension ContextControlSheet {
enum SessionBriefingMutation {
    case compact
    case clear
}

struct SessionBriefingSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionBriefingGlassCard<Content: View>: View {
    let color: Color
    var subtle = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(
                .regular.tint(color.opacity(subtle ? 0.09 : 0.14)).interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

struct SessionBriefingToolbarButton: View {
    let icon: String
    let color: Color
    var isBusy = false
    var isEnabled = true
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(color)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(isEnabled ? color : .tronTextDisabled)
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SessionBriefingMiniMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionBriefingKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
        }
    }
}

struct SessionBriefingEmptyLine: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SessionBriefingSupport {
    static func removingDuplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
}
