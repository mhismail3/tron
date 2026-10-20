import SwiftUI
import TronMobileCore

/// Settings › Trusted Projects: the default trust policy, every project with a
/// saved trust decision (the schema's `permissions.projectTrust` instances),
/// and Add Project. Adding
/// records an explicit Not trusted decision through the ordinary settings
/// change path, so a project joins the list without being granted trust;
/// trusting it is the row's own toggle and its confirmation.
struct TrustedProjectsSettingsView: View {
    static let key = "permissions.projectTrust"
    static let policyKey = "permissions.defaultProjectTrust"
    /// The keys this sheet owns; More Settings does not repeat them.
    static let keys: Set<String> = [key, policyKey]

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tronSettingsVisualTheme) private var theme
    @PresentationState private var choosingFolder = false
    @PresentationState private var adding = false

    private var target: JSONValue { SettingsTarget.global.gatewayTarget }
    private var accent: Color { theme?.accent ?? .tronCyan }

    /// The projects already listed. A folder inside one is its own project: the
    /// trust store resolves the nearest saved decision, so it gets its own row.
    private var listedProjects: [String] {
        model.settingsSnapshot(for: target)?.resolution.keys
            .filter { $0.key == Self.key }.compactMap { $0.qualifiers?["project"] } ?? []
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                TronSettingsGroup(nil) {
                    SettingsRendererView(target: target, writeLayer: "mac", presentation: .keys([Self.policyKey]), detailedKeys: true)
                }
                SettingsRendererView(target: target, writeLayer: "mac", presentation: .instances(key: Self.key), embedded: true)
                Button { choosingFolder = true } label: {
                    TronSettingsRow(
                        icon: "plus",
                        title: "Add Project",
                        accent: accent,
                        titleColor: TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : accent
                    )
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: accent, interactive: true)
                .disabled(adding)
                .accessibilityIdentifier("trusted-projects-add")
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Trusted Projects")
        .tronManagedSheet(isPresented: $choosingFolder, identity: "settings.trusted-projects.add") {
            WorkspaceBrowser { path in add(path) }
        }
    }

    private func add(_ path: String) {
        guard !adding, !listedProjects.contains(path) else { return }
        adding = true
        let change = JSONValue.object([
            "key": .string(Self.key), "layer": .string("mac"), "op": .string("set"),
            "qualifiers": .object(["project": .string(path)]), "value": .bool(false),
        ])
        // An accepted command, not a presentation read: it is not cancelled with the view.
        Task { @MainActor in
            defer { adding = false }
            do {
                try await model.changeSetting(target: target, change: change)
                model.noteSettingsChanged()
            } catch is CancellationError {
                return
            } catch {
                model.presentError(error)
            }
        }
    }
}
