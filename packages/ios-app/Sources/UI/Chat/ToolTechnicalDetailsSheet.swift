import SwiftUI

struct ToolTechnicalDetailsSheet: View {
    let tool: ChatToolPresentation
    let presentation: ToolDetailPresentation
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { tool.error ? .tronError : ChatSemanticPillRole.tool.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    protocolMetadata
                    payload("Request", value: tool.request ?? .null)
                    payload("Result", value: ToolTechnicalResultResolver.resolve(tool))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Technical details", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.toolDetail)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private var protocolMetadata: some View {
        TronTechnicalMetadataSection(
            title: "Execution",
            items: executionMetadata,
            accent: accent
        )
    }

    private var executionMetadata: [TronTechnicalMetadataItem] {
        var items = [
            TronTechnicalMetadataItem(title: "Tool", value: presentation.displayTitle, icon: presentation.icon),
            TronTechnicalMetadataItem(
                title: "Status",
                value: tool.subtitle,
                icon: tool.error ? "exclamationmark.triangle.fill" : "waveform.path.ecg"
            ),
        ]
        if !tool.id.isEmpty {
            items.append(.init(title: "Call ID", value: tool.id, icon: "number"))
        }
        if let sequence = tool.progressSequence {
            items.append(.init(title: "Progress sequence", value: String(sequence), icon: "arrow.triangle.2.circlepath"))
        }
        if tool.outputTruncated {
            items.append(.init(title: "Readable output", value: "Bounded by Gateway", icon: "text.badge.minus"))
        }
        if presentation.kind == .bash, presentation.primaryPreview?.isBounded == true {
            items.append(.init(
                title: "Command preview",
                value: "Bounded; complete command is in Request JSON below",
                icon: "text.badge.minus"
            ))
        }
        if let startedAt = tool.startedAt {
            items.append(.init(title: "Started", value: startedAt, icon: "play"))
        }
        if let lastProgressAt = tool.lastProgressAt {
            items.append(.init(title: "Last update", value: lastProgressAt, icon: "clock.arrow.circlepath"))
        }
        if let completedAt = tool.completedAt {
            items.append(.init(title: "Completed", value: completedAt, icon: "checkmark"))
        }
        if let duration = tool.elapsedMilliseconds() {
            items.append(.init(
                title: "Duration",
                value: ToolTiming.format(milliseconds: duration),
                icon: "timer"
            ))
        }
        return items
    }

    private func payload(_ title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("\(title) JSON")
            TronTechnicalJSONRow(
                value: value,
                title: "Inspect \(title) JSON",
                subtitle: ToolTechnicalPayloadSummary.summary(for: value),
                sheetTitle: "\(title) JSON",
                accent: accent
            )
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        TronTechnicalSectionLabel(title)
    }
}

enum ToolTechnicalPayloadSummary {
    static func summary(for value: JSONValue) -> String {
        if let object = value.objectValue {
            return "\(object.count) top-level field\(object.count == 1 ? "" : "s")"
        }
        if let array = value.arrayValue {
            return "\(array.count) top-level item\(array.count == 1 ? "" : "s")"
        }
        return "Scalar protocol value"
    }
}
