import SwiftUI

struct NewSessionCardIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

struct NewSessionCardCaption: View {
    let caption: String
    var font: Font = TronTypography.codeCaption

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear
                .frame(width: 16, height: 1)

            Text(caption)
                .font(font)
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NewSessionSetupCard: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let color: Color
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    NewSessionCardIcon(systemName: icon, color: color)

                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 10)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(color)
                    } else {
                        Text(value)
                            .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                            .foregroundStyle(isDisabled ? .tronTextDisabled : color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .truncationMode(.middle)
                    }
                }

                NewSessionCardCaption(caption: caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .glassEffect(
            .regular.tint(color.opacity(0.15)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled ? 0.62 : 1)
    }
}

struct NewSessionErrorCard: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronError)

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronError)

                Button("Dismiss", action: onDismiss)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()
        }
        .padding(12)
        .glassEffect(
            .regular.tint(Color.tronError.opacity(0.22)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
