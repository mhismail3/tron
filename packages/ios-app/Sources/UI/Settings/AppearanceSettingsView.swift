import SwiftUI

struct AppearanceSettingsView: View {
    @State private var appearance = AppearanceSettings.shared
    @State private var fonts = FontSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 20) {
                TronSettingsGroup("Color Mode") {
                    VStack(spacing: 0) {
                        ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            if index > 0 { TronSettingsDivider() }
                            Button { appearance.mode = mode } label: {
                                TronSettingsRow(icon: mode.icon, title: mode.label) {
                                    if appearance.mode == mode {
                                        Image(systemName: "checkmark")
                                            .font(TronTypography.buttonSM)
                                            .foregroundStyle(Color.tronAccentText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.label)
                            .accessibilityValue(appearance.mode == mode ? "Selected" : "")
                        }
                    }
                }

                TronSettingsGroup("Text Font", accent: .tronPurple) {
                    VStack(alignment: .leading, spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Text Font") {
                            FontFamilySelectionView(title: "Text Font", selection: $fonts.selectedFamily, families: FontFamily.textFamilies)
                        } label: {
                            TronSettingsRow(icon: "textformat", title: "Font", subtitle: fonts.selectedFamily.displayName, accent: .tronPurple)
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(TronFont.body(16))
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                        if fonts.selectedFamily.isVariable {
                            TronSettingsDivider(accent: .tronPurple)
                            axisSlider(
                                "Text weight",
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
                                value: axisBinding(fonts.selectedFamily, axis),
                                range: axis.range(for: fonts.selectedFamily),
                                minimum: axis.minLabel,
                                maximum: axis.maxLabel
                            )
                        }
                    }
                }

                TronSettingsGroup("Code Font", accent: .tronCyan) {
                    VStack(alignment: .leading, spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Code Font") {
                            FontFamilySelectionView(title: "Code Font", selection: $fonts.selectedMonoFamily, families: FontFamily.monoFamilies)
                        } label: {
                            TronSettingsRow(icon: "curlybraces", title: "Font", subtitle: fonts.selectedMonoFamily.displayName, accent: .tronCyan)
                        }
                        TronSettingsDivider(accent: .tronCyan)
                        Text("let result = await tron.run()")
                            .font(TronFont.mono(14))
                            .foregroundStyle(Color.tronAccentText)
                            .textSelection(.enabled)
                            .frame(minHeight: 44, alignment: .leading)
                            .padding(14)
                        if fonts.selectedMonoFamily.isVariable {
                            TronSettingsDivider(accent: .tronCyan)
                            axisSlider(
                                "Code weight",
                                value: axisBinding(fonts.selectedMonoFamily, .weight),
                                range: fonts.selectedMonoFamily.weightRange,
                                minimum: "Light",
                                maximum: "Heavy"
                            )
                        }
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
        value: Binding<Double>,
        range: ClosedRange<Double>,
        minimum: String,
        maximum: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
            Slider(value: value, in: range) {
                Text(title).font(TronTypography.bodySM)
            } minimumValueLabel: {
                Text(minimum).font(TronTypography.caption)
            } maximumValueLabel: {
                Text(maximum).font(TronTypography.caption)
            }
        }
        .padding(14)
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
