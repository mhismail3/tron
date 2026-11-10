import SwiftUI
import TronMobileCore

enum PackageProvidesKind: String, CaseIterable, Identifiable, Sendable {
    case skills = "Skills"
    case subagents = "Subagents"
    case prompts = "Prompts"
    case tools = "Tools"
    case commands = "Commands"
    case themes = "Themes"

    var id: String { rawValue }

    var projectResourceKind: ProjectResourceKind? {
        switch self {
        case .skills: .skills
        case .prompts: .prompts
        case .subagents: .subagents
        case .tools: .tools
        case .commands: .commands
        case .themes: nil
        }
    }

    var icon: String { projectResourceKind?.icon ?? "paintpalette" }
    @MainActor var accent: Color { projectResourceKind?.accent ?? .tronTeal }

    var detail: String {
        switch self {
        case .skills: "Guidance the agent can load when a task matches."
        case .prompts: "Reusable prompt templates available as slash commands."
        case .subagents: "Agent definitions available for delegated work."
        case .tools: "Actions this package's extensions register."
        case .commands: "Slash commands this package's extensions register."
        case .themes: "Terminal themes this package installs."
        }
    }

    func names(in provides: PackageProvides) -> [String] {
        switch self {
        case .skills: provides.skills
        case .prompts: provides.prompts
        case .subagents: provides.subagents
        case .tools: provides.tools
        case .commands: provides.commands
        case .themes: provides.themes
        }
    }
}

struct PackageProvidesGroup: Identifiable, Equatable, Sendable {
    let kind: PackageProvidesKind
    let names: [String]

    var id: String { kind.rawValue }
}

struct PackageProvidesContent: Equatable, Sendable {
    static let absent = PackageProvidesContent(groups: [], reported: false)

    let groups: [PackageProvidesGroup]
    let reported: Bool

    var isEmpty: Bool { reported && groups.isEmpty }
}

enum PackageProvidesPresentation {
    static func content(from provides: PackageProvides?) -> PackageProvidesContent {
        guard let provides else { return .absent }
        return PackageProvidesContent(
            groups: PackageProvidesKind.allCases.compactMap { kind in
                let names = kind.names(in: provides)
                return names.isEmpty ? nil : PackageProvidesGroup(kind: kind, names: names)
            },
            reported: true
        )
    }
}

struct PackageDetailSheet: View {
    let package: PackageSummary
    let providesDiagnostic: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronBlue }

    private var content: PackageProvidesContent {
        PackageProvidesPresentation.content(from: package.provides)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section, lazy: true, hidesLoneHeading: true) {
                    header
                    if let conflict = package.conflict {
                        TronSettingsNotice(message: conflict.message)
                    }
                    if let notice = package.nodeRequirement?.notice {
                        TronSettingsNotice(message: notice)
                    }
                    if let providesDiagnostic {
                        TronSettingsNotice(message: providesDiagnostic)
                    }
                    ForEach(content.groups) { group in
                        providesGroup(group)
                    }
                    if content.isEmpty {
                        TronSettingsGroup("Provides", accent: accent) {
                            TronSettingsRow(
                                icon: "tray",
                                title: "This package provides no agent resources.",
                                accent: accent
                            )
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Package", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
    }

    private var header: some View {
        TronSettingsGroup("Installed package", accent: accent) {
            TronSettingsRow(
                icon: "shippingbox.fill",
                title: package.source,
                subtitle: [package.scopeLabel, package.nodeRequirement?.tag, package.filtered ? "Filtered" : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                titleIsIdentifier: true,
                accent: accent,
                subtitleColor: .tronTextSecondary
            ) {
                ResourceDistributionTag(distribution: .external, accent: accent)
            }
        }
    }

    private func providesGroup(_ group: PackageProvidesGroup) -> some View {
        TronSettingsGroup(
            group.kind.rawValue,
            detail: "\(group.names.count) provided · \(group.kind.detail)",
            accent: group.kind.accent,
            surfaceStyle: .scrollOptimized
        ) {
            VStack(spacing: 0) {
                ForEach(Array(group.names.enumerated()), id: \.element) { index, name in
                    if index > 0 { TronSettingsDivider(accent: group.kind.accent) }
                    TronSettingsRow(
                        icon: group.kind.icon,
                        title: name,
                        titleIsIdentifier: true,
                        accent: group.kind.accent
                    )
                }
            }
        }
        .environment(\.tronSettingsVisualTheme, nil)
    }
}
