import SwiftUI

/// General, read-only presentation surface for retained extension content.
///
/// Retained widgets are not transcript rows and not ambient composer chrome.
/// A discrete extension event belongs in a notification pill; retained state is
/// only visible when the user opens this sheet. The sheet owns no extension
/// execution and starts no provider work: it renders the content it was given
/// and disappears with the sheet.
struct ExtensionWidgetsSheet: View {
    /// Content is an input, not a second read path: the presenting route owns
    /// where retained content comes from, so this sheet stays a pure function of
    /// the authoritative projection it was given.
    let content: ExtensionRetainedContent
    /// Bounded count of admitted-but-unpresentable content, if any.
    var omittedContentCount: Int = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if content.isEmpty {
                    TronGlassCard(accent: .tronSlate) {
                        TronPlaceholderState(
                            title: "No extension content",
                            detail: "Extensions can share status and progress here while the session is open.",
                            icon: "square.on.square.dashed",
                            accent: .tronIndigo
                        )
                    }
                    .padding(18)
                } else {
                    retainedContent
                }
            }
            .tronNavigationTitle("Extension content", accent: .tronIndigo)
            .toolbar { doneToolbar }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronIndigo)
        .tronPresentation()
        .accessibilityIdentifier("extension-widgets-sheet")
    }

    @ViewBuilder
    private var retainedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if omittedContentCount > 0 {
                    ExtensionContentNotice(
                        text: "Some extension content is not shown on this device yet."
                    )
                }
                ForEach(content.producers, id: \.self) { producer in
                    ExtensionContentSectionHeader(title: producer)
                    ForEach(content.entries(forProducer: producer)) { entry in
                        ExtensionContentEntryCard(entry: entry)
                    }
                }
            }
            .padding(18)
        }
        .tronScrollEdgeChrome()
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronIndigo)
            }
            .accessibilityLabel("Done")
        }
    }
}

/// Section header follows the same caption/muted treatment as the Subagents
/// sheet's section headers.
private struct ExtensionContentSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One read-only retained entry. Card geometry and internal padding match the
/// existing activity rows so the sheet reads as part of the same system.
private struct ExtensionContentEntryCard: View {
    let entry: ExtensionRetainedContent.Entry

    var body: some View {
        TronGlassCard(accent: .tronIndigo, cornerRadius: 14) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.style {
        case .text(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
        case .frame(let frame):
            ExtensionFrameView(frame: frame)
        case .status(let text):
            Text(text)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}

/// A partial projection is disclosed rather than presented as complete.
private struct ExtensionContentNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            Text(text)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}
