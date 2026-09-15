import SwiftUI

/// Observation copy uses the source date, not a later correction's save time.
/// Canonical IDs and qualifications remain intact, but belong in technical details.
struct KnowledgeObservationPresentation {
    let record: KnowledgeRecord
    let observation: KnowledgeObservationContent

    init?(record: KnowledgeRecord) {
        guard case .observation(let observation) = record.content else { return nil }
        self.record = record
        self.observation = observation
    }

    var statement: String { record.summary }
    var scope: String { record.scope.label }
    var observedAt: String { observation.items.first?.observedAt ?? record.createdAt }
    var date: Date? { GatewayTimestamp.parse(observedAt) }
    var sessionID: String { observation.range.sessionId }
    var entryID: String { observation.range.fromEntryId }

    var recordMetadata: [TronTechnicalMetadataItem] {
        [
            .init(title: "Record ID", value: record.id, icon: "number"),
            .init(title: "Revision", value: record.revisionId, icon: "clock.arrow.circlepath"),
            .init(title: "Created", value: record.createdAt, icon: "calendar"),
            .init(title: "Updated", value: record.updatedAt, icon: "clock"),
            .init(title: "Recorded by", value: record.provenance.actor.rawValue.capitalized, icon: "person.crop.circle"),
        ]
    }

    var sourceMetadata: [TronTechnicalMetadataItem] {
        let range = observation.range
        var items: [TronTechnicalMetadataItem] = [
            .init(title: "Session ID", value: range.sessionId, icon: "bubble.left.and.bubble.right"),
            .init(title: "First entry", value: range.fromEntryId, icon: "arrow.up.to.line"),
            .init(title: "Last entry", value: range.toEntryId, icon: "arrow.down.to.line"),
            .init(title: "Entries", value: range.entryIds.joined(separator: ", "), icon: "list.bullet"),
            .init(title: "Digest", value: range.entryDigest, icon: "number"),
        ]
        if let branch = range.branchId { items.append(.init(title: "Branch", value: branch, icon: "arrow.triangle.branch")) }
        if let project = range.projectId { items.append(.init(title: "Project", value: project, icon: "folder")) }
        if let invocations = range.invocationIds, !invocations.isEmpty {
            items.append(.init(title: "Invocations", value: invocations.joined(separator: "\n"), icon: "play"))
        }
        return items
    }

    var observerMetadata: [TronTechnicalMetadataItem] {
        guard let observer = observation.observer else { return [] }
        var items = [TronTechnicalMetadataItem(title: "Prompt version", value: observer.promptVersion, icon: "text.bubble")]
        if let model = observer.model { items.insert(.init(title: "Model", value: model, icon: "cpu"), at: 0) }
        return items
    }

    func itemMetadata(_ item: KnowledgeObservationItem) -> [TronTechnicalMetadataItem] {
        [
            .init(title: "Attribution", value: item.attribution.rawValue.capitalized, icon: "person"),
            .init(title: "Certainty", value: item.certainty.rawValue.capitalized, icon: "questionmark.circle"),
            .init(title: "Observed", value: item.observedAt, icon: "calendar"),
        ]
    }
}

/// Shared statement/tag/date layout; dashboard cards contain nothing else.
struct KnowledgeObservationStatement: View {
    let presentation: KnowledgeObservationPresentation
    var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            Text(presentation.statement)
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(preview ? 4 : nil)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
                Text(presentation.scope)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronKnowledgeText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.tronKnowledge.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
                if let date = presentation.date {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KnowledgeDetailSheet: View {
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onChanged: () async -> Void
    let onOpenDraft: (KnowledgeRecord) -> Void
    let onOpenSession: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            KnowledgeDetailView(record: record, origin: origin, onChanged: onChanged,
                                onOpenDraft: onOpenDraft, onOpenSession: onOpenSession)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronKnowledge)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronPresentation()
    }
}

struct KnowledgeObservationTechnicalDetailsSheet: View {
    let presentation: KnowledgeObservationPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    TronTechnicalMetadataSection(title: "Record", items: presentation.recordMetadata, accent: .tronKnowledge)
                    TronTechnicalMetadataSection(title: "Source", items: presentation.sourceMetadata, accent: .tronKnowledge)
                    if !presentation.observerMetadata.isEmpty {
                        TronTechnicalMetadataSection(title: "Observer", items: presentation.observerMetadata, accent: .tronKnowledge)
                    }
                    ForEach(Array(presentation.observation.items.enumerated()), id: \.offset) { index, item in
                        TronTechnicalMetadataSection(
                            title: presentation.observation.items.count == 1 ? "Attribution" : "Item \(index + 1)",
                            items: presentation.itemMetadata(item), accent: .tronKnowledge)
                    }
                    // Preserve less-common provenance, correction links, and temporal
                    // fields without turning the ordinary statement into an inspector.
                    if let value = try? JSONValue.encode(presentation.record) {
                        TronTechnicalJSONRow(value: value, title: "Complete record", subtitle: "Exact retained revision and evidence",
                                             sheetTitle: "Knowledge record JSON", accent: .tronKnowledge)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Technical details", accent: .tronKnowledge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronKnowledge)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronPresentation()
    }
}
