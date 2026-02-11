import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSection: View {
    @State private var appearanceSettings = AppearanceSettings.shared
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { appearanceSettings.mode },
                set: { appearanceSettings.mode = $0 }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            thinkingIndicatorPickerRow

            fontPickerRow

            axisSliders
        } header: {
            Text("Appearance")
                .font(TronTypography.caption)
        } footer: {
            footerText
        }
        .listSectionSpacing(16)
    }

    // MARK: - Thinking Indicator Picker

    private var thinkingIndicatorPickerRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: appearanceSettings.thinkingIndicatorStyle.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 32, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appearanceSettings.thinkingIndicatorStyle.displayName)
                        .font(TronTypography.headline)
                        .foregroundStyle(.tronTextPrimary)
                    Text("Thinking animation")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                }

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ThinkingIndicatorStyle.allCases) { style in
                        indicatorChip(style)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func indicatorChip(_ style: ThinkingIndicatorStyle) -> some View {
        let isSelected = appearanceSettings.thinkingIndicatorStyle == style
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                appearanceSettings.thinkingIndicatorStyle = style
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.system(size: 12))
                Text(style.displayName)
                    .font(TronTypography.caption)
            }
            .foregroundStyle(isSelected ? .tronSurface : .tronTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.tronEmerald : Color.tronSurfaceElevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : Color.tronBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Font Picker

    private var fontPickerRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Aa")
                    .font(TronFontLoader.createFont(
                        size: 28,
                        weight: .medium,
                        family: fontSettings.selectedFamily
                    ))
                    .foregroundStyle(.tronEmerald)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fontSettings.selectedFamily.displayName)
                        .font(TronTypography.headline)
                        .foregroundStyle(.tronTextPrimary)
                    Text(fontSettings.selectedFamily.shortDescription)
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                }

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FontFamily.allCases) { family in
                        fontChip(family)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fontChip(_ family: FontFamily) -> some View {
        let isSelected = fontSettings.selectedFamily == family
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                fontSettings.selectedFamily = family
            }
        } label: {
            Text(family.displayName)
                .font(TronTypography.caption)
                .foregroundStyle(isSelected ? .tronSurface : .tronTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.tronEmerald : Color.tronSurfaceElevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : Color.tronBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Axis Sliders

    @ViewBuilder
    private var axisSliders: some View {
        let axes = fontSettings.selectedFamily.customAxes
        if !axes.isEmpty {
            ForEach(axes) { axis in
                axisSlider(axis)
            }
        }
    }

    private func axisSlider(_ axis: FontAxis) -> some View {
        let family = fontSettings.selectedFamily
        let range = axis.range(for: family)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(axis.displayName)
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                Text(axisValueLabel(axis, family: family))
                    .font(TronTypography.subheadline)
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
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
            } maximumValueLabel: {
                Text(axis.maxLabel)
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
            }
            .tint(.tronEmerald)
        }
        .padding(.vertical, 4)
    }

    private func axisValueLabel(_ axis: FontAxis, family: FontFamily) -> String {
        let value = fontSettings.axisValue(for: family, axis: axis)
        switch axis {
        case .casual:
            return String(format: "%.2f", value)
        }
    }

    // MARK: - Footer

    private var footerText: some View {
        Group {
            if fontSettings.selectedFamily == .recursive {
                Text("Auto follows your system appearance setting. Font style adjusts the casual axis — Linear is precise, Casual is playful.")
            } else {
                Text("Auto follows your system appearance setting. Code and file paths always use Recursive mono.")
            }
        }
        .font(TronTypography.caption2)
    }
}
