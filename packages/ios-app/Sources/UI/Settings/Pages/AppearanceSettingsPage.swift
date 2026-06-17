import SwiftUI

struct AppearanceSettingsPage: View {
    @Binding var confirmArchive: Bool
    @State private var appearanceSettings = AppearanceSettings.shared
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        SettingsPageContainer(title: "App") {
            themeCard
            confirmArchivingCard
            fontCard
            codeFontCard
            thinkingIndicatorCard
        }
    }

    // MARK: - Behavior Cards

    private var confirmArchivingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Behavior")

            SettingsCard {
                SettingsRow(icon: "questionmark.circle", label: "Confirm Archiving") {
                    Toggle("", isOn: $confirmArchive)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "Ask before archiving a session.")
        }
    }

    // MARK: - Theme Card

    private var themeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Theme")

            SettingsCard {
                HStack {
                    Image(systemName: appearanceSettings.mode.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Color Mode")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    themeToggle
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: "Auto follows your system appearance setting.")
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
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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
            SettingsSectionHeader(title: "Text Font")

            SettingsCard {
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
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(fontSettings.selectedFamily.shortDescription)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().padding(.leading, 12)

                // Font family chips grouped by category
                fontCategoryChips(
                    families: FontFamily.textFamilies,
                    selected: fontSettings.selectedFamily
                ) { family in
                    fontSettings.selectedFamily = family
                }

                // Axis sliders (only for fonts with user-facing axes)
                let axes = fontSettings.selectedFamily.customAxes.filter { !$0.isAutomatic }
                if !axes.isEmpty {
                    Divider().padding(.leading, 12)

                    ForEach(axes) { axis in
                        axisSlider(axis, family: fontSettings.selectedFamily)
                    }
                }
            }

            SettingsCaption(text: "Used for messages, headings, and UI text.")
        }
    }

    // MARK: - Code Font Card

    private var codeFontCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Code Font")

            SettingsCard {
                // Preview + info row
                HStack(spacing: 12) {
                    Text("{;}")
                        .font(TronFontLoader.createFont(
                            size: 22,
                            weight: .medium,
                            mono: true,
                            family: fontSettings.selectedMonoFamily
                        ))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fontSettings.selectedMonoFamily.displayName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(fontSettings.selectedMonoFamily.shortDescription)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().padding(.leading, 12)

                // Mono font chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FontFamily.monoFamilies, id: \.id) { family in
                            fontSelectionChip(
                                family: family,
                                isSelected: fontSettings.selectedMonoFamily == family
                            ) {
                                fontSettings.selectedMonoFamily = family
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                // Axis sliders for mono family (Recursive's CASL axis)
                let axes = fontSettings.selectedMonoFamily.customAxes.filter { !$0.isAutomatic }
                if !axes.isEmpty {
                    Divider().padding(.leading, 12)

                    ForEach(axes) { axis in
                        axisSlider(axis, family: fontSettings.selectedMonoFamily)
                    }
                }
            }

            SettingsCaption(text: "Used for code blocks, file paths, and terminal output.")
        }
    }

    // MARK: - Font Chips

    private func fontCategoryChips(
        families: [FontFamily],
        selected: FontFamily,
        onSelect: @escaping (FontFamily) -> Void
    ) -> some View {
        let grouped = Dictionary(grouping: families) { $0.category }
        let categories: [FontCategory] = [.sans, .serif]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(categories, id: \.self) { category in
                if let categoryFamilies = grouped[category] {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text(category.displayName)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronTextMuted)
                                .frame(width: 32, alignment: .leading)

                            ForEach(categoryFamilies, id: \.id) { family in
                                fontSelectionChip(
                                    family: family,
                                    isSelected: selected == family
                                ) {
                                    onSelect(family)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fontSelectionChip(
        family: FontFamily,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                action()
            }
        } label: {
            Text(family.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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

    private func axisSlider(_ axis: FontAxis, family: FontFamily) -> some View {
        let range = axis.range(for: family)
        let binding = Binding(
            get: { fontSettings.axisValue(for: family, axis: axis) },
            set: { fontSettings.setAxisValue(for: family, axis: axis, value: $0) }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(axis.displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(axisValueLabel(axis, family: family))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Slider(
                value: binding,
                in: range.lowerBound...range.upperBound
            ) {
                Text(axis.displayName)
            } minimumValueLabel: {
                Text(axis.minLabel)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            } maximumValueLabel: {
                Text(axis.maxLabel)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
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
        case .weight:
            return String(format: "%.0f", value)
        case .casual:
            return String(format: "%.2f", value)
        case .opticalSize:
            return String(format: "%.0fpt", value)
        }
    }

    // MARK: - Thinking Indicator Card

    private var thinkingIndicatorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Thinking Indicator")

            SettingsCard {
                // Current indicator preview
                HStack(spacing: 12) {
                    Image(systemName: appearanceSettings.thinkingIndicatorStyle.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appearanceSettings.thinkingIndicatorStyle.displayName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Thinking animation")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
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

            SettingsCaption(text: "Animation shown while the model is thinking.")
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
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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
