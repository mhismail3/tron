import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appearanceSettings = AppearanceSettings.shared
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    themeCard
                    fontCard
                    thinkingIndicatorCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Appearance")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }

    // MARK: - Theme Card

    private var themeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Theme")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: appearanceSettings.mode.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Color Mode")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                Spacer()
                themeToggle
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Auto follows your system appearance setting.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    private var themeToggle: some View {
        HStack(spacing: 4) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let isSelected = appearanceSettings.mode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        appearanceSettings.mode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text(mode.label)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? .tronSurface : .tronEmerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.tronEmerald : Color.tronEmerald.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Font Card

    private var fontCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Font")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                // Preview + info row
                HStack(spacing: 12) {
                    Text("Aa")
                        .font(TronFontLoader.createFont(
                            size: 28,
                            weight: .medium,
                            family: fontSettings.selectedFamily
                        ))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fontSettings.selectedFamily.displayName)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(fontSettings.selectedFamily.shortDescription)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().padding(.leading, 12)

                // Font family chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FontFamily.allCases) { family in
                            fontChip(family)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                // Axis sliders (only for Recursive's CASL axis)
                let axes = fontSettings.selectedFamily.customAxes
                if !axes.isEmpty {
                    Divider().padding(.leading, 12)

                    ForEach(axes) { axis in
                        axisSlider(axis)
                    }
                }
            }
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Code and file paths always use Recursive mono.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    private func fontChip(_ family: FontFamily) -> some View {
        let isSelected = fontSettings.selectedFamily == family
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                fontSettings.selectedFamily = family
            }
        } label: {
            Text(family.displayName)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(isSelected ? .tronSurface : .tronTextPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.tronEmerald : Color.tronEmerald.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    private func axisSlider(_ axis: FontAxis) -> some View {
        let family = fontSettings.selectedFamily
        let range = axis.range(for: family)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(axis.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(axisValueLabel(axis, family: family))
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Slider(
                value: Binding(
                    get: { fontSettings.axisValue(for: family, axis: axis) },
                    set: { fontSettings.setAxisValue(for: family, axis: axis, value: $0) }
                ),
                in: range.lowerBound...range.upperBound
            ) {
                Text(axis.displayName)
            } minimumValueLabel: {
                Text(axis.minLabel)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            } maximumValueLabel: {
                Text(axis.maxLabel)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
            .tint(.tronEmerald)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func axisValueLabel(_ axis: FontAxis, family: FontFamily) -> String {
        let value = fontSettings.axisValue(for: family, axis: axis)
        switch axis {
        case .casual:
            return String(format: "%.2f", value)
        }
    }

    // MARK: - Thinking Indicator Card

    private var thinkingIndicatorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Thinking Indicator")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                // Current indicator preview
                HStack(spacing: 12) {
                    Image(systemName: appearanceSettings.thinkingIndicatorStyle.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appearanceSettings.thinkingIndicatorStyle.displayName)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Thinking animation")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().padding(.leading, 12)

                // Indicator style chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThinkingIndicatorStyle.allCases) { style in
                            indicatorChip(style)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Animation shown while the model is thinking.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    private func indicatorChip(_ style: ThinkingIndicatorStyle) -> some View {
        let isSelected = appearanceSettings.thinkingIndicatorStyle == style
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appearanceSettings.thinkingIndicatorStyle = style
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: style.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text(style.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(isSelected ? .tronSurface : .tronTextPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.tronEmerald : Color.tronEmerald.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}
