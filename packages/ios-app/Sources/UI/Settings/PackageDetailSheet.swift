import SwiftUI

/// One kind of resource an installed package provides, in the order the detail
/// sheet presents them. Skills, subagents, prompts, tools and commands reuse the
/// Project Resources kind they share a name with, so their group icon and colour
/// cannot drift from that sheet's; themes have no Project Resources kind and
/// keep the terminal-theme icon/colour Extensions and Locations already use.
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

    /// What the group's names are, in this session-free read's own terms: a
    /// package's tools and commands exist when its extensions load, not in the
    /// session Project Resources describes.
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

/// One package's Provides projection: the non-empty groups in presentation
/// order, plus whether the Gateway reported `provides` at all. An older Gateway
/// that omits the field supplies no groups and no placeholder, while a package
/// whose reported kinds are all empty says so in one line.
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

/// What one Installed row opened: the source and scope the row shows, then the
/// names the package provides. Every row here is external, so the shared
/// distribution tag labels the header once instead of repeating on each name.
struct PackageDetailSheet: View {
    let package: PackageSummary
    let providesDiagnostic: String?
    @Environment(\.dismiss) private var dismiss
    private let accent = Color.tronBlue

    private var content: PackageProvidesContent {
        PackageProvidesPresentation.content(from: package.provides)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    header
                    // The diagnostic explains missing kinds before the reader
                    // infers that the package contributes none of them.
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
                            .foregroundStyle(accent)
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
                subtitle: [package.scopeLabel, package.filtered ? "Filtered" : nil]
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
        // Resource kinds keep their own accents; the sheet theme belongs to the
        // package chrome, as it does on Project Resources.
        .environment(\.tronSettingsVisualTheme, nil)
    }
}
