import SwiftUI

/// A producer-authored message delivered into the mounted session's agent turn.
/// This is conversation input, not a tool invocation, so it shares the trailing
/// edge with user and steering messages while retaining distinct provenance.
struct SessionInputMessageView: View {
    let item: TranscriptItem
    @State private var showingDetails = false

    private var originTitle: String {
        item.sessionInput?.origin?.owner?.title ?? "Extension message"
    }

    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }

    var body: some View {
        Button { showingDetails = true } label: {
            BoundedTrailingContentLayout(maxWidth: UserPromptTextLayoutPolicy.maximumWidth) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(originTitle, systemImage: "arrow.down.message.fill")
                        .font(TronFont.mono(10, weight: .medium))
                        .foregroundStyle(Color.tronCyan)
                    UserPromptText(text: messageText)
                }
                .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                .padding(.top, ChatPromptContainerStyle.topPadding)
                .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                .fixedSize(horizontal: false, vertical: true)
            }
            .glassEffect(
                .regular.tint(Color.tronCyan.opacity(0.14)).interactive(),
                in: RoundedRectangle(
                    cornerRadius: ChatPromptContainerStyle.cornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message from \(originTitle). \(messageText)")
        .accessibilityHint("Shows message origin and technical details")
        .sheet(isPresented: $showingDetails) {
            SessionInputDetailsSheet(item: item)
        }
    }
}

private struct SessionInputDetailsSheet: View {
    let item: TranscriptItem
    @Environment(\.dismiss) private var dismiss

    private var origin: ExtensionToolOrigin? { item.sessionInput?.origin }
    private var messageText: String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No text content" : text
    }
    private var contentJSON: String {
        (try? JSONValue.encode(item.content ?? []).prettyPrinted) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    detailGroup("Message") {
                        Text(messageText)
                            .font(TronFont.body(14))
                            .foregroundStyle(Color.tronTextPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    detailGroup("Origin") {
                        detailRow("Extension", origin?.owner?.title ?? "Unknown extension")
                        detailRow("Source", origin?.source ?? "Not attributed")
                        detailRow("Custom type", item.customType ?? "Unknown")
                        detailRow("Delivery", "Triggered an agent turn")
                    }

                    detailGroup("Canonical identity") {
                        detailRow("Entry", item.id)
                        detailRow("Timestamp", item.timestamp)
                    }

                    if let details = item.details {
                        detailGroup("Producer details") {
                            technicalText(details.prettyPrinted)
                        }
                    }

                    if !contentJSON.isEmpty {
                        detailGroup("Content payload") {
                            technicalText(contentJSON)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.tronBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Session message")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        TronToolbarTextLabel("Done", systemImage: "checkmark")
                    }
                    .tronToolbarAction()
                }
            }
        }
        .tronTopBlur(.sheet)
    }

    private func detailGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(TronFont.mono(10, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
            VStack(alignment: .leading, spacing: 9) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tronBorder.opacity(0.65), lineWidth: 0.5)
                }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TronFont.body(11))
                .foregroundStyle(Color.tronTextMuted)
            Text(value)
                .font(TronFont.mono(12))
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func technicalText(_ value: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(value)
                .font(TronFont.mono(11))
                .foregroundStyle(Color.tronTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
