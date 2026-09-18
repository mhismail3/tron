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
/// `preview` is the dense catalogue form: one step down the type scale with a
/// shorter statement window, so a long observation list stays scannable. The
/// detail sheet keeps the full-size statement.
struct KnowledgeObservationStatement: View {
    let presentation: KnowledgeObservationPresentation
    var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: preview ? TronSpacing.sm : TronSpacing.md) {
            Text(presentation.statement)
                .font(preview ? TronTypography.bodySM : TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(preview ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
                Text(presentation.scope)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronKnowledgeText)
                    .padding(.horizontal, preview ? 6 : 8)
                    .padding(.vertical, preview ? 2 : 4)
                    .background(Color.tronKnowledge.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
                if let date = presentation.date {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(preview ? TronTypography.caption : TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bounded copy for the observation coverage container. Opaque cut ids stay in
/// the mutation owner; the dashboard only needs a citation short enough that a
/// dense row cannot be dominated by a hash.
enum KnowledgeCoveragePresentationPolicy {
    /// Short enough that a citation cannot compete with the reason copy, even
    /// beside the row's two action capsules.
    static let citationPrefixLength = 8

    static func actionable(_ cuts: [KnowledgeObservationCoverage]) -> [KnowledgeObservationCoverage] {
        cuts.filter { $0.disposition == .pending || $0.disposition == .failed || $0.disposition == .unavailable }
    }

    static func settledLabel(_ coverage: KnowledgeCoverageSummary) -> String {
        "\(coverage.observedCount + coverage.emptyCount + coverage.excludedCount) settled"
    }

    static func summaryTitle(_ coverage: KnowledgeCoverageSummary) -> String {
        switch coverage.remainingCount {
        case 0: "No cuts need attention"
        case 1: "1 cut needs attention"
        default: "\(coverage.remainingCount) cuts need attention"
        }
    }

    /// The attention breakdown while cuts remain; otherwise the settled counts
    /// the previous container always showed inline.
    static func summaryDetail(_ coverage: KnowledgeCoverageSummary) -> String {
        guard coverage.remainingCount > 0 else {
            return "Observed \(coverage.observedCount) · Empty \(coverage.emptyCount) · Excluded \(coverage.excludedCount)"
        }
        return "pending \(coverage.pendingCount) · failed \(coverage.failedCount) · unavailable \(coverage.unavailableCount)"
    }

    static func title(_ disposition: KnowledgeCoverageDisposition) -> String {
        switch disposition {
        case .pending: "Observation pending"
        case .failed: "Observation failed"
        case .unavailable: "Observation unavailable"
        case .observed, .empty, .excluded: "Observation settled"
        }
    }

    static func icon(_ disposition: KnowledgeCoverageDisposition) -> String {
        switch disposition {
        case .pending: "clock"
        case .failed: "exclamationmark.triangle"
        case .unavailable: "questionmark.circle"
        case .observed: "checkmark.circle"
        case .empty: "circle.dashed"
        case .excluded: "eye.slash"
        }
    }

    static func accent(_ disposition: KnowledgeCoverageDisposition) -> Color {
        switch disposition {
        case .pending: .tronKnowledge
        case .failed, .unavailable: .tronAmber
        case .observed, .empty, .excluded: .tronTextSecondary
        }
    }

    /// One bounded citation line for a dense cut row. The entry range is
    /// abbreviated rather than dropped: it still identifies the affected cut,
    /// while "Open" carries the exact session/entry citation.
    static func citation(_ range: KnowledgeObservationRange) -> String {
        "\(short(range.fromEntryId))–\(short(range.toEntryId)) · session \(short(range.sessionId))"
    }

    static func short(_ identifier: String) -> String {
        identifier.count > citationPrefixLength ? "\(identifier.prefix(citationPrefixLength))…" : identifier
    }
}

/// The dashboard's coverage container. One tappable summary row expands to the
/// cuts that need attention, so a healthy corpus costs a single row and every
/// actionable cut keeps its own Open/Clear target instead of being merged into
/// a combined container element.
struct KnowledgeCoverageSection: View {
    let coverage: KnowledgeCoverageSummary
    let cuts: [KnowledgeObservationCoverage]
    let showsInitialLoading: Bool
    let loadingMore: Bool
    let canLoadMore: Bool
    let errorText: String?
    let mutationErrorText: String?
    let clearingCutID: String?
    let allowsActions: Bool
    let onOpenSession: (KnowledgeObservationCoverage) -> Void
    let onRequestClear: (KnowledgeObservationCoverage) -> Void
    let onLoadMore: () -> Void
    /// The dashboard owns disclosure state so a Gateway change resets it with
    /// the rest of its presentation state.
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var attentionCuts: [KnowledgeObservationCoverage] { KnowledgeCoveragePresentationPolicy.actionable(cuts) }
    private var needsAttention: Bool { coverage.remainingCount > 0 }
    /// Only the summary row expands; an error notice stays visible outside the
    /// disclosure so a failed coverage read cannot hide behind a collapsed row.
    private var canExpand: Bool { needsAttention || canLoadMore || showsInitialLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Observation coverage")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronKnowledge)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: TronSpacing.md)
                Text(KnowledgeCoveragePresentationPolicy.settledLabel(coverage))
                    .font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(Color.tronTextMuted)
            }
            VStack(spacing: 0) {
                summaryRow
                if let errorText {
                    TronSettingsDivider(accent: .tronKnowledge)
                    notice("Coverage unavailable: \(errorText)")
                }
                if let mutationErrorText {
                    TronSettingsDivider(accent: .tronKnowledge)
                    notice(mutationErrorText)
                }
                if expanded { expandedContent }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.10)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var summaryRow: some View {
        let row = TronSettingsRow(
            icon: KnowledgeCoveragePresentationPolicy.icon(needsAttention ? .failed : .observed),
            title: KnowledgeCoveragePresentationPolicy.summaryTitle(coverage),
            subtitle: KnowledgeCoveragePresentationPolicy.summaryDetail(coverage),
            subtitleLineLimit: 2,
            accent: needsAttention ? .tronAmber : .tronKnowledge
        ) {
            if canExpand {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(Color.tronKnowledge)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        if canExpand {
            Button {
                withAnimation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Observation coverage")
            .accessibilityValue("\(KnowledgeCoveragePresentationPolicy.summaryTitle(coverage)). \(KnowledgeCoveragePresentationPolicy.summaryDetail(coverage))")
            .accessibilityHint(expanded ? "Hides observation cuts" : "Shows observation cuts that need attention")
        } else {
            row
        }
    }

    @ViewBuilder private var expandedContent: some View {
        if showsInitialLoading {
            TronSettingsDivider(accent: .tronKnowledge)
            TronLoadingState(label: "Loading coverage…", accent: .tronKnowledge)
                .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                .padding(.vertical, TronSpacing.xl)
        }
        ForEach(attentionCuts) { cut in
            TronSettingsDivider(accent: .tronKnowledge)
            cutRow(cut)
        }
        if canLoadMore {
            TronSettingsDivider(accent: .tronKnowledge)
            Button(loadingMore ? "Loading…" : "Inspect more coverage") { onLoadMore() }
                .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
                .disabled(loadingMore || !allowsActions)
                .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                .padding(.vertical, TronSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cutRow(_ cut: KnowledgeObservationCoverage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.xl) {
            Image(systemName: KnowledgeCoveragePresentationPolicy.icon(cut.disposition))
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(KnowledgeCoveragePresentationPolicy.accent(cut.disposition))
                .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(KnowledgeCoveragePresentationPolicy.title(cut.disposition))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(cut.reason ?? "No reason recorded")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(KnowledgeCoveragePresentationPolicy.citation(cut.range))
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: TronSpacing.md)
            HStack(spacing: TronSpacing.sm) {
                Button { onOpenSession(cut) } label: { TronInlineActionLabel("Open", accent: .tronKnowledge) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open originating session")
                if cut.disposition == .failed || cut.disposition == .unavailable {
                    Button { onRequestClear(cut) } label: {
                        TronInlineActionLabel("Clear", isWorking: clearingCutID == cut.id, accent: .tronKnowledge)
                    }
                    .buttonStyle(.plain)
                    .disabled(clearingCutID != nil)
                    .accessibilityLabel("Clear observation failure")
                }
            }
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, TronSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ message: String) -> some View {
        TronSettingsNotice(message: message, accent: .tronAmber)
            .padding(TronSpacing.md)
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
