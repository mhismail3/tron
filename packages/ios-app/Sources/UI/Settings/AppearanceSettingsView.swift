import SwiftUI

struct AppearanceSettingsView: View {
    @State private var appearance = AppearanceSettings.shared
    @State private var fonts = FontSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color Mode")
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    TronSegmentedControl(
                        options: AppearanceMode.allCases.map { (label: $0.label, value: $0) },
                        selection: $appearance.mode,
                        accent: .tronEmerald
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Color Mode")
                }

                TronSettingsGroup("Text Font", accent: .tronPurple) {
                    VStack(alignment: .leading, spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Text Font") {
                            FontFamilySelectionView(title: "Text Font", selection: $fonts.selectedFamily, families: FontFamily.textFamilies)
                        } label: {
                            TronValueRow(icon: "textformat", title: "Font", value: fonts.selectedFamily.displayName, accent: .tronPurple)
                        }
                        if fonts.selectedFamily.isVariable {
                            TronSettingsDivider(accent: .tronPurple)
                            axisSlider(
                                "Text weight",
                                icon: "textformat.size",
                                value: axisBinding(fonts.selectedFamily, .weight),
                                range: fonts.selectedFamily.weightRange,
                                minimum: "Light",
                                maximum: "Heavy"
                            )
                        }
                        ForEach(fonts.selectedFamily.customAxes.filter { !$0.isAutomatic && $0 != .weight }) { axis in
                            TronSettingsDivider(accent: .tronPurple)
                            axisSlider(
                                axis.displayName,
                                icon: "slider.horizontal.3",
                                value: axisBinding(fonts.selectedFamily, axis),
                                range: axis.range(for: fonts.selectedFamily),
                                minimum: axis.minLabel,
                                maximum: axis.maxLabel
                            )
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(TronFont.body(16))
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                }

                TronSettingsGroup("Code Font", accent: .tronCyan) {
                    VStack(alignment: .leading, spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Code Font") {
                            FontFamilySelectionView(title: "Code Font", selection: $fonts.selectedMonoFamily, families: FontFamily.monoFamilies)
                        } label: {
                            TronValueRow(icon: "curlybraces", title: "Font", value: fonts.selectedMonoFamily.displayName, accent: .tronCyan)
                        }
                        if fonts.selectedMonoFamily.isVariable {
                            TronSettingsDivider(accent: .tronCyan)
                            axisSlider(
                                "Code weight",
                                icon: "textformat.size",
                                value: axisBinding(fonts.selectedMonoFamily, .weight),
                                range: fonts.selectedMonoFamily.weightRange,
                                minimum: "Light",
                                maximum: "Heavy"
                            )
                        }
                        ForEach(fonts.selectedMonoFamily.customAxes.filter { !$0.isAutomatic && $0 != .weight }) { axis in
                            TronSettingsDivider(accent: .tronCyan)
                            axisSlider(
                                axis.displayName,
                                icon: "slider.horizontal.3",
                                value: axisBinding(fonts.selectedMonoFamily, axis),
                                range: axis.range(for: fonts.selectedMonoFamily),
                                minimum: axis.minLabel,
                                maximum: axis.maxLabel
                            )
                        }
                        TronSettingsDivider(accent: .tronCyan)
                        Text("let result = await tron.run()")
                            .font(TronFont.mono(14))
                            .foregroundStyle(Color.tronAccentText)
                            .textSelection(.enabled)
                            .frame(minHeight: 44, alignment: .leading)
                            .padding(14)
                    }
                }

                TronSettingsGroup("About Fonts", accent: .tronSlate) {
                    Text("Text and code font choices match the established Tron experience. Terminal themes on the Mac remain independent.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Appearance")
    }

    private func axisSlider(
        _ title: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        minimum: String,
        maximum: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
            Slider(value: value, in: range) {
                Text(title).font(TronTypography.bodySM)
            } minimumValueLabel: {
                Text(minimum).font(TronTypography.caption)
            } maximumValueLabel: {
                Text(maximum).font(TronTypography.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func axisBinding(_ family: FontFamily, _ axis: FontAxis) -> Binding<Double> {
        Binding(
            get: { fonts.axisValue(for: family, axis: axis) },
            set: { fonts.setAxisValue(for: family, axis: axis, value: $0) }
        )
    }
}

struct FontFamilySelectionView: View {
    let title: String
    @Binding var selection: FontFamily
    let families: [FontFamily]
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronGlassCard(accent: .tronPurple) {
                VStack(spacing: 0) {
                    ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                        if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                        Button { selection = family } label: {
                            TronSettingsRow(
                                icon: family == selection ? "checkmark.circle.fill" : "circle",
                                title: family.displayName,
                                subtitle: family.shortDescription,
                                accent: family == selection ? .tronPurple : .tronSlate
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(family.displayName)
                        .accessibilityValue(selection == family ? "Selected" : "")
                    }
                }
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title, accent: .tronPurple)
    }
}
