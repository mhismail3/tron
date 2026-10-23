import SwiftUI
import TronMobileCore

/// A resource's body in its detail sheet. Commands and subagents preview it in
/// a glass card whose View All opens the shared document reader (#1655);
/// prompts and skills read in full. The sheet owns loading and the reader.
struct ProjectResourceContentSection: View {
    let selection: ProjectResourceSelection
    let detail: CommandResourceDetail?
    let subagentDetail: SubagentResourceDetail?
    let loadError: String?
    let accent: Color
    let retry: () -> Void
    /// The sheet presents the reader, so it stays mounted above this lazy row.
    let read: (ProjectResourceReading) -> Void

    private var readsInReader: Bool { selection.kind == .commands || selection.kind == .subagents }

    /// A subagent's body is its definition's Markdown; a command's is its source.
    private var bodySource: CommandInfo.Source {
        selection.kind == .subagents ? .prompt : selection.commandInfo?.source ?? .extension
    }

    /// The source excerpt (480 characters or ten lines), ended at a whole line
    /// so a Markdown body never stops mid-word; View All shows the rest.
    private static func excerpt(_ text: String) -> String {
        let preview = ComposerResourceContentPresentation.preview(text, source: .extension, sourceTruncated: false)
        guard preview.isTruncated, let lineEnd = preview.text.range(of: "\n", options: .backwards) else { return preview.text }
        return String(preview.text[..<lineEnd.lowerBound])
    }

    private var loadedContent: (text: String, truncated: Bool)? {
        if let content = detail?.content, !content.isEmpty { return (content, detail?.contentTruncated == true) }
        if let content = subagentDetail?.content, !content.isEmpty { return (content, subagentDetail?.contentTruncated == true) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TronTechnicalSectionLabel("Content").containerValue(\.tronSettingsSection, false)
            if readsInReader, let content = loadedContent {
                TronGlassCard(accent: accent) {
                    ComposerResourceContentBody(preview: .init(text: Self.excerpt(content.text), isTruncated: false),
                                                source: bodySource)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-resource-content")
                    TronSettingsDivider(accent: accent)
                    Button {
                        read(ProjectResourceReading(id: selection.id.uuidString, title: selection.title, text: content.text,
                                                    source: bodySource, truncated: content.truncated))
                    } label: {
                        TronSettingsRow(icon: "text.alignleft", title: "View All",
                                        subtitle: "\(content.text.count.formatted()) characters", accent: accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project-resource-view-all")
                }
            } else {
                Group {
                    if let detail, let content = detail.content, !content.isEmpty {
                        let preview = ComposerResourceContentPresentation.preview(
                            content,
                            source: selection.commandInfo?.source ?? .extension,
                            sourceTruncated: detail.contentTruncated == true
                        )
                        ComposerResourceContentBody(
                            preview: preview,
                            source: selection.commandInfo?.source ?? .extension
                        )
                    } else if detail != nil || subagentDetail != nil {
                        Text("This resource has no body content.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                    } else if let loadError {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(loadError)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(accent)
                        }
                    } else if selection.commandInfo == nil && selection.kind != .subagents {
                        Text("This resource does not expose body content.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                    } else {
                        TronLoadingState(label: "Loading resource content…", accent: accent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tronScrollSurface(accent: accent, cornerRadius: 16, tintOpacity: 0.06)
            }
        }
    }
}

/// A command's or subagent's whole body, opened from its View All row.
struct ProjectResourceReading: Identifiable {
    let id: String
    let title: String
    let text: String
    let source: CommandInfo.Source
    let truncated: Bool
}

/// The shared document reader every instructions and Home text reader uses,
/// with the resource's own body renderer.
struct ProjectResourceReader: View {
    let reading: ProjectResourceReading

    var body: some View {
        TronDocumentSheet(title: reading.title, detents: [.medium, .large]) {
            ScrollView {
                ComposerResourceContentBody(preview: .init(text: reading.text, isTruncated: reading.truncated), source: reading.source)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-resource-reading")
            }
            .tronScrollEdgeChrome()
        }
    }
}
