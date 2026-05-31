import SwiftUI

@available(iOS 26.0, *)
struct NewSessionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.tronTextMuted.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }
}

@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
struct NewSessionShortcutButton: View {
    let icon: String
    let title: String
    let caption: String
    let color: Color
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    NewSessionCardIcon(systemName: icon, color: color)

                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 0)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(color)
                    }
                }

                NewSessionCardCaption(
                    caption: caption,
                    font: TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        .glassEffect(
            .regular.tint(color.opacity(0.16)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled && !isBusy ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
struct NewSessionProfileCard: View {
    let selectedProfile: NewSessionProfileMode
    var isDisabled: Bool = false
    let onSelect: (NewSessionProfileMode) -> Void

    private var caption: String {
        selectedProfile.caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NewSessionCardIcon(systemName: "slider.horizontal.3", color: selectedProfile.color)

                Text("Profile")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(selectedProfile.color)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 10)

                Text(selectedProfile.shortValue)
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(isDisabled ? .tronTextDisabled : selectedProfile.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }

            HStack(spacing: 8) {
                ForEach(NewSessionProfileMode.allCases) { profile in
                    let isSelected = profile == selectedProfile

                    Button {
                        onSelect(profile)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: profile.icon)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))

                            Text(profile.title)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(isDisabled ? .tronTextDisabled : profile.color)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(profile.color.opacity(isSelected ? 0.22 : 0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(profile.color.opacity(isSelected ? 0.5 : 0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }

            NewSessionCardCaption(caption: caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(
            .regular.tint(selectedProfile.color.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
struct NewSessionWorktreeCard: View {
    @Binding var isOn: Bool
    let caption: String
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                NewSessionCardIcon(systemName: "arrow.triangle.branch", color: .tronAmber)

                Text("Worktree")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronAmber)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 10)

                Text(isOn ? "Isolated" : "Current")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(isDisabled ? .tronTextDisabled : .tronAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.tronAmber)
                    .disabled(isDisabled)
            }

            NewSessionCardCaption(caption: caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(Color.tronAmber.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
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
