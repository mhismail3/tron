import SwiftUI

/// One bounded projection supplies titles, rows and their shared provenance
/// captions. Full resolver metadata stays in the technical drill-down.
struct PackageResolvedResourcesSection: View {
    let resources: JSONValue

    var body: some View {
        let presentation = PackageResolvedResourcesPresentation(resources: resources)
        VStack(alignment: .leading, spacing: 18) {
            ForEach(presentation.categories) { category in
                if category.items.isEmpty {
                    TronSettingsGroup(category.kind.title, accent: category.kind.accent) {
                        TronSettingsRow(icon: "tray", title: "No \(category.kind.title.lowercased()) are currently available.",
                                        accent: category.kind.accent)
                    }
                } else {
                    TronSettingsGroup(category.kind.title, detail: category.summary, accent: category.kind.accent) {
                        VStack(spacing: 0) {
                            ForEach(Array(category.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { TronSettingsDivider(accent: category.kind.accent) }
                                TronSettingsRow(icon: item.enabled ? "checkmark.circle.fill" : "minus.circle",
                                                title: item.displayName,
                                                subtitle: category.hasSharedSource ? nil : item.sourceDescription,
                                                accent: item.enabled ? category.kind.accent : .tronSlate,
                                                subtitleColor: .tronTextSecondary) {
                                    TronDynamicValue(text: item.statusDescription, color: .tronTextSecondary)
                                }
                                .accessibilityValue(item.statusDescription)
                            }
                        }
                    }
                    .tronSettingsCaption(category.caption)
                }
            }
            if resources.objectValue?.isEmpty == false {
                TronTechnicalJSONRow(value: resources, title: "Technical Details",
                                     subtitle: "View paths, provenance, status, and other resolved resource data",
                                     sheetTitle: "Resolved Resources JSON", accent: .tronSlate)
            }
        }
    }
}
