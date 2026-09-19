import SwiftUI

struct HookEventDetailView: View {
    let event: HookEventRecord
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false
    @State private var infoDetent: PresentationDetent = .medium

    private var providerLabels: [String: String] {
        HookInventoryPresentation.extensionLabels(for: event.providers.map(\.extension))
    }

    private var technicalValue: JSONValue {
        .object([
            "event": .string(event.descriptor.identifier),
            "title": .string(event.descriptor.title),
            "supportedByPinnedSDK": .bool(event.descriptor.isSupported),
            "providers": .array(event.providers.map { .object([
                "name": .string($0.extension.name),
                "displayName": .string(providerLabels[$0.extension.id] ?? $0.extension.friendlyName),
                "count": .number(Double($0.count)),
                "path": $0.extension.path.map(JSONValue.string) ?? .null,
                "source": $0.extension.source.map(JSONValue.string) ?? .null,
                "scope": $0.extension.scope.map(JSONValue.string) ?? .null,
            ]) }),
        ])
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    Text(event.descriptor.purpose)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                    TronSettingsGroup("Providers", detail: event.providers.isEmpty ? "No registered handlers" : "\(event.handlerCount) registered handler\(event.handlerCount == 1 ? "" : "s") · \(event.providers.count) provider\(event.providers.count == 1 ? "" : "s")", accent: accent, surfaceStyle: .scrollOptimized) {
                        if event.providers.isEmpty {
                            TronSettingsRow(icon: "minus.circle", title: "No registered handlers", subtitle: "This supported event is not registered by an extension in the selected runtime.", accent: accent)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(event.providers.enumerated()), id: \.offset) { index, provider in
                                    if index > 0 { TronSettingsDivider(accent: accent) }
                                    TronSettingsRow(icon: "bolt.horizontal.circle", title: providerLabels[provider.extension.id] ?? provider.extension.friendlyName, subtitle: "\(provider.count) registered handler\(provider.count == 1 ? "" : "s")", accent: accent) {
                                        ComposerResourceBadges(hookProvenance: provider.extension.provenance, accent: accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .defaultScrollAnchor(.top)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsInfo = true } label: {
                        Image(systemName: "info.circle").font(TronTypography.buttonSM).foregroundStyle(accent)
                    }
                    .accessibilityLabel("Event technical information")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: event.descriptor.title, accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronManagedSheet(isPresented: $showsInfo, identity: "hook-event-info.\(event.id)") {
            TechnicalJSONSheet(
                value: technicalValue,
                title: "Event Details",
                accent: accent,
                detent: $infoDetent,
                onEdit: nil
            )
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
    }
}
