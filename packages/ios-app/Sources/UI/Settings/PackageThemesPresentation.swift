import SwiftUI

struct PackageThemeItem: Identifiable, Equatable, Sendable {
    let path: String
    let enabled: Bool
    let source: String?
    let scope: String?
    let origin: String?

    var id: String { path }
    var displayName: String { ProjectResourceTitlePresentation.resourcePathTitle(path) }
    var statusDescription: String { enabled ? "Ready to use" : "Turned off" }

    var sourceDescription: String? {
        if source == "auto" { return "Discovered automatically" }
        if let source, !source.isEmpty { return "From \(source)" }
        return nil
    }
}

/// Resolved theme files. Pi themes style the terminal, not this app (Appearance
/// owns the app's color mode and fonts), so a theme an installed package owns is
/// listed in that package's detail sheet and the Extensions sheet keeps one
/// Local themes group for the themes no package owns.
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
                scope: metadata?["scope"]?.stringValue,
                origin: metadata?["origin"]?.stringValue
            )
        }
    }

    /// Themes no installed package owns. A theme whose package is gone from the
    /// listing has no detail sheet to appear in, so it stays local rather than
    /// vanishing from the app.
    static func localItems(from resources: JSONValue, packages: [PackageSummary]) -> [PackageThemeItem] {
        items(from: resources).filter { item in
            !packages.contains { package in
                item.origin == "package"
                    && item.source == package.source
                    && item.scope == package.scope.rawValue
            }
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
