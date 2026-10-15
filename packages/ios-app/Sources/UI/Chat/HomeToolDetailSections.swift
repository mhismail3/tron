import SwiftUI
import TronMobileCore

/// A Home tool call's detail body inside the standard tool detail sheet: a header
/// card with the call's outcome pill, then its failure, rows, Markdown texts and
/// line lists. Everything is a shared settings group, row, pill or Markdown view
/// in the tool sheet's accent; a long text opens whole in the shared reader, as a
/// Manage Home brief does.
struct HomeToolDetailSections: View {
    let presentation: HomeToolDetailPresentation
    let accent: Color
    let open: (HomeTextReading) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ForEach(Array(presentation.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-tool-detail")
    }

    private var header: some View {
        let header = presentation.header
        return TronGlassCard(accent: accent) {
            TronSettingsRow(icon: header.icon, title: header.title, subtitle: header.subtitle, subtitleLineLimit: 2, accent: accent) {
                TronStatusPill(text: header.pill, accent: Self.color(header.tone, accent: accent))
                    .accessibilityIdentifier("home-tool-outcome")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-tool-header")
    }

    static func color(_ tone: HomeToolDetailPresentation.Tone, accent: Color) -> Color {
        switch tone {
        case .success: .tronSuccess
        case .pending: .tronAmber
        case .failure: .tronError
        case .neutral: accent
        }
    }

    @ViewBuilder private func sectionView(_ section: HomeToolDetailPresentation.Section) -> some View {
        switch section {
        case .failure(let title, let message, let issues):
            TronSettingsGroup(title, accent: .tronError) {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "exclamationmark.triangle.fill", title: message, accent: .tronError,
                                    titleFont: TronTypography.sans(size: TronTypography.sizeBody))
                    ForEach(issues, id: \.self) { issue in
                        TronSettingsDivider(accent: .tronError)
                        TronSettingsRow(icon: "xmark.circle", title: issue, accent: .tronError,
                                        titleFont: TronTypography.code(size: TronTypography.sizeBodySM))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-tool-failure")
        case .rows(let title, let detail, let rows):
            rowsGroup(title: title, detail: detail, rows: rows)
        case .text(let id, let title, let text):
            textGroup(id: id, title: title, text: text)
        case .lines(let id, let title, let detail, let lines):
            TronSettingsGroup(title, detail: detail, accent: accent) {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { TronSettingsDivider(accent: accent) }
                        Button { open(HomeTextReading(id: "\(id)-\(line.id)", title: line.title, text: line.full)) } label: {
                            TronSettingsRow(icon: line.icon, title: line.title, subtitle: line.preview, subtitleLineLimit: 3,
                                            subtitleIsMarkdown: true, accent: accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-tool-line-\(line.id)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-tool-lines-\(id)")
        }
    }

    @ViewBuilder private func rowsGroup(title: String?, detail: String?, rows: [HomeToolDetailPresentation.Row]) -> some View {
        if let title {
            TronSettingsGroup(title, detail: detail, accent: accent) { rowList(rows) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-tool-section-\(title)")
        } else if !rows.isEmpty {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                TronGlassCard(accent: accent) { rowList(rows) }
                if let detail { TronSettingsCaption(detail, inset: 0) }
            }
        }
    }

    private func rowList(_ rows: [HomeToolDetailPresentation.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { TronSettingsDivider(accent: accent) }
                // Title over value, as every Home detail row reads.
                TronSettingsRow(icon: row.icon, title: row.title, subtitle: row.value, subtitleLineLimit: nil, accent: accent)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("home-tool-row-\(row.title)")
            }
        }
    }

    /// Markdown text, its opening lines previewed; a long text opens whole from View All.
    private func textGroup(id: String, title: String, text: String) -> some View {
        let preview = ToolTextHeadPreview.make(text)
        return TronSettingsGroup(title, accent: accent) {
            VStack(alignment: .leading, spacing: 0) {
                TronMarkdownView(text: preview.isTruncated ? preview.text : text, streaming: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-tool-text-\(id)")
                if preview.isTruncated {
                    TronSettingsDivider(accent: accent)
                    Button { open(HomeTextReading(id: id, title: title, text: text)) } label: {
                        TronSettingsRow(icon: "text.alignleft", title: "View All", accent: accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-tool-text-\(id)-view-all")
                }
            }
        }
    }
}
