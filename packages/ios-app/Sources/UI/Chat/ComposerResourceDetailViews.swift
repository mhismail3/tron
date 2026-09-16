import SwiftUI

/// Metadata is a secondary disclosure of the already loaded resource, never a
/// second fetch or another owner of the selected invocation.
struct ComposerResourceInfoSheet: View {
    let items: [TronTechnicalMetadataItem]
    let accent: Color
    let technicalValue: JSONValue?
    let technicalTitle: String?
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    init(items: [TronTechnicalMetadataItem], accent: Color, technicalValue: JSONValue? = nil, technicalTitle: String? = nil) {
        self.items = items
        self.accent = accent
        self.technicalValue = technicalValue
        self.technicalTitle = technicalTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronTechnicalMetadataSection(title: "Resource", items: items, accent: accent)
                    if let technicalValue {
                        TronTechnicalJSONRow(
                            value: technicalValue,
                            sheetTitle: technicalTitle ?? "Resource JSON"
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Resource Info", accent: accent)
            .toolbar {
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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

struct ComposerResourceContentBody: View {
    let preview: ComposerResourceContentPresentation.Preview
    let source: CommandInfo.Source

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if source == .extension {
                Text(preview.text)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(Color.tronTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TronMarkdownView(text: preview.text, streaming: false)
                    .textSelection(.enabled)
            }
            if preview.isTruncated {
                Label("Content truncated", systemImage: "text.badge.minus")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
            }
        }
    }
}
