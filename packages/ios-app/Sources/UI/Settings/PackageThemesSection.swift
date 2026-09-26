import SwiftUI

/// Resolved theme files from installed packages. Pi themes style the terminal,
/// not this app (Appearance owns the app's color mode and fonts), so the
/// Extensions sheet keeps this list rather than losing it to Appearance.
struct PackageThemesSection: View {
    let resources: JSONValue

    var body: some View {
        let items = PackageThemesPresentation.items(from: resources)
        VStack(alignment: .leading, spacing: 18) {
            if items.isEmpty {
                TronSettingsGroup("Themes", accent: .tronTeal) {
                    TronSettingsRow(icon: "tray", title: "No themes are currently available.", accent: .tronTeal)
                }
                .environment(\.tronSettingsVisualTheme, nil)
            } else {
                TronSettingsGroup("Themes", detail: PackageThemesPresentation.summary(for: items), accent: .tronTeal) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { TronSettingsDivider(accent: .tronTeal) }
                            TronSettingsRow(icon: item.enabled ? "checkmark.circle.fill" : "minus.circle",
                                            title: item.displayName,
                                            subtitle: PackageThemesPresentation.hasSharedSource(items) ? nil : item.sourceDescription,
                                            accent: item.enabled ? .tronTeal : .tronSlate,
                                            subtitleColor: .tronTextSecondary) {
                                TronDynamicValue(text: item.statusDescription, color: .tronTextSecondary)
                            }
                            .accessibilityValue(item.statusDescription)
                        }
                    }
                }
                .tronSettingsCaption(PackageThemesPresentation.caption(for: items))
                .environment(\.tronSettingsVisualTheme, nil)
            }
        }
    }
}

struct PackageThemeItem: Identifiable, Equatable, Sendable {
    let path: String
    let enabled: Bool
    let source: String?
    let scope: String?

    var id: String { path }
    var displayName: String { ProjectResourceTitlePresentation.resourcePathTitle(path) }
    var statusDescription: String { enabled ? "Ready to use" : "Turned off" }

    var sourceDescription: String? {
        if source == "auto" { return "Discovered automatically" }
        if let source, !source.isEmpty { return "From \(source)" }
        return nil
    }
}

enum PackageThemesPresentation {
    static func items(from resources: JSONValue) -> [PackageThemeItem] {
        let values = resources.objectValue?["themes"]?.arrayValue ?? []
        return values.compactMap { value -> PackageThemeItem? in
            guard let object = value.objectValue,
                  let path = object["path"]?.stringValue else { return nil }
            let metadata = object["metadata"]?.objectValue
            return PackageThemeItem(
                path: path,
                enabled: object["enabled"]?.boolValue != false,
                source: metadata?["source"]?.stringValue,
                scope: metadata?["scope"]?.stringValue
            )
        }
    }

    static func hasSharedSource(_ items: [PackageThemeItem]) -> Bool {
        Set(items.map(\.source)).count == 1
    }

    static func summary(for items: [PackageThemeItem]) -> String {
        guard !items.isEmpty else { return "None resolved" }
        let disabled = items.count - items.count(where: \.enabled)
        return disabled == 0 ? "\(items.count) ready to use" : "\(items.count - disabled) ready · \(disabled) turned off"
    }

    /// Shared provenance appears once as a caption; only a mixed source list
    /// repeats it per row.
    static func caption(for items: [PackageThemeItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let scopes = Set(items.map { $0.scope == "user" ? "global" : $0.scope })
        let scope = switch scopes {
        case ["global"]: "Available in every project."
        case ["project"]: "Available in the current project."
        case ["temporary"]: "Available in this session."
        default: "Source and scope details are available in Technical Details."
        }
        let provenance = hasSharedSource(items) ? items.first?.sourceDescription : nil
        return [provenance, scope].compactMap { $0 }.joined(separator: " · ")
    }
}
