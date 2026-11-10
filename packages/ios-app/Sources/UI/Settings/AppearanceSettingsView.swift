import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    @PresentationState private var behavior = AppLocalBehaviorSettings.shared
    @PresentationState private var appearance = AppearanceSettings.shared
    @PresentationState private var fonts = FontSettings.shared
    @PresentationState private var iconChangeFailed = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 20, lazy: true, hidesLoneHeading: true) {
                TronSettingsGroup("Dashboard", accent: .tronPrimary) {
                    TronChoiceRow(icon: "rectangle.3.group", title: "Dashboard View",
                                  choices: DashboardSessionSortMode.allCases.map { TronChoice(id: $0, label: $0.rawValue, detail: $0.detail) },
                                  selected: behavior.dashboardFilter.sortMode) { behavior.dashboardFilter.setSortMode($0) }
                    TronSettingsDivider()
                    TronSelectionSheetRow(icon: "server.rack", title: "Visible Servers",
                        value: behavior.dashboardFilter.isAllSelected ? "All servers" : "\(behavior.dashboardFilter.selectedProfileIDs.count) server\(behavior.dashboardFilter.selectedProfileIDs.count == 1 ? "" : "s")") {
                        VisibleServersSettingsView(settings: behavior)
                    }
                    TronSettingsDivider()
                    TronNumberSettingRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Chats per project",
                        detail: "Shown by default",
                        value: $behavior.dashboardChatsPerProject
                    )
                }
                .tronSettingsVisualTheme(inheriting: .tronPrimary)
                .tronSettingsCaption("Choose 1–100 chats (default 10). Show more reveals another batch of this size. Applies to every project on this iPhone.")

                TronSettingsGroup("Subagent Activity", accent: .tronPrimary) {
                    TronValueRow(
                        icon: "circle.dotted",
                        title: "Show finished subagents",
                        detail: "Keep the subagent button visible after work finishes",
                        accent: .tronPrimary
                    ) {
                        TronInlineMenu(retentionLabel(behavior.subagentRecentFinishedRetentionMinutes), accent: .tronPrimary) {
                            ForEach(Array(AppLocalBehaviorSettings.subagentRecentFinishedRetentionRange), id: \.self) { minutes in
                                Button(retentionLabel(minutes)) {
                                    behavior.subagentRecentFinishedRetentionMinutes = minutes
                                }
                            }
                        }
                        .accessibilityLabel("Show finished subagents")
                        .accessibilityValue(retentionLabel(behavior.subagentRecentFinishedRetentionMinutes))
                    }
                }
                .tronSettingsVisualTheme(inheriting: .tronPrimary)
                .tronSettingsCaption("Only active hides the button as soon as all subagents finish. This applies to every session on this iPhone. Finished subagents are always available in Manage Session’s Subagent History.")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Color Mode")
                        .tronSectionHeading()
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    TronSegmentedControl(
                        options: AppearanceMode.allCases.map { (label: $0.label, value: $0) },
                        selection: $appearance.mode,
                        accent: .tronPrimary,
                        minimumHeight: 40
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Color Mode")
                }

                TronSettingsGroup("Theme color", accent: .tronPrimary, surfaceStyle: .uncontained) {
                    ThemeColorPicker(selection: appearance.themeColor, isApplying: appearance.isApplyingAppIcon) { color in
                        Task { @MainActor in
                            iconChangeFailed = false
                            do { try await appearance.selectTheme(color) }
                            catch { iconChangeFailed = true }
                        }
                    }
                }

                .tronSettingsCaption("Selecting a theme also applies its matching app icon. iOS shows an icon-change alert and controls Home Screen appearance and notification icons.")

                if iconChangeFailed {
                    TronSettingsNotice(message: "Theme applied, but the app icon could not be changed. Select the theme again to retry.")
                        .accessibilityIdentifier("theme-icon-error")
                }

                TronSettingsGroup("Text Font", accent: .tronPurple) {
                    VStack(alignment: .leading, spacing: 0) {
                        TronSelectionSheetRow(icon: "textformat", title: "Font", value: fonts.selectedFamily.displayName,
                                              accessibilityLabel: "Text Font", accent: .tronPurple) {
                            FontFamilySelectionView(
                                title: "Text Font",
                                selection: $fonts.selectedFamily,
                                families: FontFamily.textFamilies,
                                previewsMonospacedVariant: false
                            )
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
                        TronSelectionSheetRow(icon: "curlybraces", title: "Font", value: fonts.selectedMonoFamily.displayName,
                                              accessibilityLabel: "Code Font", accent: .tronCyan) {
                            FontFamilySelectionView(
                                title: "Code Font",
                                selection: $fonts.selectedMonoFamily,
                                families: FontFamily.monoFamilies,
                                previewsMonospacedVariant: true
                            )
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
                            .padding(14)
                    }
                }

                .tronSettingsCaption("Text and code font choices match the established Tron experience. Terminal themes on the Mac remain independent.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .tronScrollEdgeChrome()
        .onChange(of: model.dashboardServerSources.map(\.profileID), initial: true) { _, ids in
            behavior.dashboardFilter.reconcile(profileIDs: ids)
        }
        .tronNavigationTitle("Appearance")
    }

    private func retentionLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")"
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
                Text(minimum).font(TronTypography.settingsRowSubtext)
            } maximumValueLabel: {
                Text(maximum).font(TronTypography.settingsRowSubtext)
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

private struct ThemeColorPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: ThemeColor
    let isApplying: Bool
    let select: (ThemeColor) -> Void
    private static let spacing: CGFloat = 10

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(ThemeColor.allCases) { color in
                    tile(color)
                        .containerRelativeFrame(.horizontal, count: dynamicTypeSize.isAccessibilitySize ? 5 : 3,
                                                span: dynamicTypeSize.isAccessibilitySize ? 4 : 1, spacing: Self.spacing)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }

    private func tile(_ color: ThemeColor) -> some View {
        let isSelected = color == selection
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { select(color) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(color.ink)
                Text(color.label)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: .infinity, alignment: .topLeading)
            .overlay { if isSelected { shape.strokeBorder(color.ink, lineWidth: 2) } }
            .tronGlassSurface(accent: color.surfaceTint, cornerRadius: 16,
                              tintOpacity: isSelected ? 0.34 : 0.18, interactive: true,
                              respectsSettingsTheme: false)
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(color.label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("theme-color-\(color.rawValue)")
    }
}

struct FontFamilySelectionView: View {
    let title: String
    @Binding var selection: FontFamily
    let families: [FontFamily]
    let previewsMonospacedVariant: Bool
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
                                accent: family == selection ? .tronPurple : .tronSlate,
                                titleFont: TronFontLoader.createFont(
                                    size: TronTypography.sizeBody,
                                    weight: .semibold,
                                    mono: previewsMonospacedVariant,
                                    family: family
                                )
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
