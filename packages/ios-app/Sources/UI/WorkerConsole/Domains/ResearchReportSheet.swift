import SwiftUI

private enum ResearchReportSection: String, CaseIterable {
    case answer = "Answer"
    case claims = "Claims"
    case sources = "Sources"
    case quality = "Quality"
}

struct ResearchReportSheet: View {
    let report: ResearchReport
    @State private var selectedSection = ResearchReportSection.answer

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    TronSegmentedControl(
                        options: ResearchReportSection.allCases.map { ($0.rawValue, $0) },
                        selection: $selectedSection,
                        accent: .tronCyan
                    )
                    content
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Research Report", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: report.answer) {
                        Image(systemName: "square.and.arrow.up")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronCyan)
                    }
                    .accessibilityLabel("Share research answer")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(report.question)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                badge(WorkerConsolePresentation.displayLabel(report.status), color: statusColor)
                badge("\(report.sources.count) sources", color: .tronCyan)
                badge("\(report.supportedClaimCount)/\(report.claims.count) supported", color: .tronPurple)
            }
            if let searchLimitation = report.searchLimitation {
                Label(searchLimitation, systemImage: "key.slash")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let timestamp = WorkerConsolePresentation.timestamp(report.generatedAt) {
                Text(timestamp)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(14)
        .sectionFill(statusColor, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .answer: answerContent
        case .claims: claimsContent
        case .sources: sourcesContent
        case .quality: qualityContent
        }
    }

    private var answerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkerConsoleSectionHeader(
                title: WorkerConsolePresentation.displayLabel(report.answerFormat),
                detail: "The coordinator's canonical synthesized deliverable."
            )
            Text(report.answer)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private var claimsContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            WorkerConsoleSectionHeader(
                title: "Claims and citations",
                detail: "Every claim keeps its classification, rationale, uncertainty, gaps, and linked citation records."
            )
            if report.claims.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "quote.bubble", text: "This report contains no claims.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(report.claims) { claim in
                        ResearchClaimCard(
                            claim: claim,
                            citations: report.citations.filter { claim.citationIds.contains($0.citationId) }
                        )
                    }
                }
            }
        }
    }

    private var sourcesContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            WorkerConsoleSectionHeader(
                title: "Source manifest",
                detail: "Canonical source identity, freshness metadata, and claim-linked excerpts."
            )
            if report.sources.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "link.badge.plus", text: "No sources were available for this report.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(report.sources) { source in
                        ResearchSourceCard(
                            source: source,
                            citations: report.citations.filter { $0.sourceId == source.sourceId }
                        )
                    }
                }
            }
        }
    }

    private var qualityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            qualitySection(
                title: "Specialist outcomes",
                detail: "The coordinator's recorded status for each worker in this report."
            ) {
                ForEach(report.outcomes) { outcome in
                    ResearchOutcomeRow(outcome: outcome)
                }
            }

            qualitySection(
                title: "Contradictions",
                detail: "Conflicting evidence retained by the report."
            ) {
                if report.contradictions.isEmpty {
                    WorkerConsoleInlineEmptyState(symbol: "checkmark.seal", text: "No contradictions recorded.")
                } else {
                    ForEach(report.contradictions) { contradiction in
                        qualityText(
                            contradiction.point,
                            symbol: "arrow.left.arrow.right",
                            color: .tronError
                        )
                    }
                }
            }

            qualitySection(
                title: "Evidence gaps",
                detail: "Missing evidence or unresolved support requirements."
            ) {
                stringRows(report.evidenceGaps, empty: "No evidence gaps recorded.", symbol: "exclamationmark.triangle", color: .tronWarning)
            }

            qualitySection(
                title: "Limitations",
                detail: "Scope and process limits recorded by the coordinator."
            ) {
                stringRows(report.limitations, empty: "No limitations recorded.", symbol: "scope", color: .tronSlate)
            }
        }
    }

    private var statusColor: Color {
        switch report.status {
        case "complete": .tronSuccess
        case "partial": .tronWarning
        default: .tronError
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func qualitySection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            WorkerConsoleSectionHeader(title: title, detail: detail)
            VStack(alignment: .leading, spacing: 9) { content() }
        }
    }

    @ViewBuilder
    private func stringRows(_ values: [String], empty: String, symbol: String, color: Color) -> some View {
        if values.isEmpty {
            WorkerConsoleInlineEmptyState(symbol: "checkmark.seal", text: empty)
        } else {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                qualityText(value, symbol: symbol, color: color)
            }
        }
    }

    private func qualityText(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct ResearchClaimCard: View {
    let claim: ResearchClaim
    let citations: [ResearchCitation]

    @State private var showDetail = false

    private var color: Color {
        switch claim.classification {
        case "supported": .tronSuccess
        case "partial": .tronWarning
        case "contradicted": .tronError
        default: .tronTextMuted
        }
    }

    var body: some View {
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(claim.claimId)
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(color)
                    Text(WorkerConsolePresentation.displayLabel(claim.classification))
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(color)
                    Spacer()
                    Text("\(citations.count) cite\(citations.count == 1 ? "" : "s")")
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
                Text(claim.text)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .sectionFill(color, cornerRadius: 11, subtle: true, interactive: true)
        .sheet(isPresented: $showDetail) {
            ResearchClaimDetailSheet(claim: claim, citations: citations, accent: color)
        }
    }
}

private struct ResearchSourceCard: View {
    let source: ResearchSource
    let citations: [ResearchCitation]

    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(source.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                HStack(spacing: 8) {
                    if let domain = source.domain { Text(domain) }
                    if let date = source.updatedDate ?? source.publishedDate { Text(date) }
                    Text("\(citations.count) citations")
                }
                .font(TronTypography.sans(size: TronTypography.sizeSM))
                .foregroundStyle(.tronTextMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .sectionFill(.tronCyan, cornerRadius: 11, subtle: true, interactive: true)
        .sheet(isPresented: $showDetail) {
            ResearchSourceDetailSheet(source: source, citations: citations)
        }
    }
}

private struct ResearchClaimDetailSheet: View {
    let claim: ResearchClaim
    let citations: [ResearchCitation]
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(claim.text)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(claim.rationale)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                    ForEach(citations) { citation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(citation.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(.tronTextPrimary)
                            ForEach(Array(citation.excerpts.enumerated()), id: \.offset) { _, excerpt in
                                Text("“\(excerpt)”")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(11)
                        .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
                    }
                    ForEach(claim.gaps, id: \.self) { gap in
                        Label(gap, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronWarning)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Claim \(claim.claimId)", color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(accent)
    }
}

private struct ResearchSourceDetailSheet: View {
    let source: ResearchSource
    let citations: [ResearchCitation]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(source.title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            Label(source.url, systemImage: "arrow.up.right.square")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(.tronCyan)
                        }
                    }
                    ForEach(citations) { citation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Claim \(citation.claimId)")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(.tronPurple)
                            ForEach(Array(citation.excerpts.enumerated()), id: \.offset) { _, excerpt in
                                Text("“\(excerpt)”")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(11)
                        .sectionFill(.tronPurple, cornerRadius: 10, subtle: true, interactive: false)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Research Source", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
    }
}

private struct ResearchOutcomeRow: View {
    let outcome: ResearchSpecialistOutcome

    private var color: Color {
        switch outcome.status {
        case "complete", "passed": .tronSuccess
        case "partial", "unavailable", "skipped": .tronWarning
        default: .tronError
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(WorkerConsolePresentation.displayLabel(outcome.role))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Spacer()
                Text(WorkerConsolePresentation.displayLabel(outcome.status))
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(color)
            }
            let metrics = outcomeMetrics
            if !metrics.isEmpty {
                Text(metrics.joined(separator: " · "))
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextMuted)
            }
            if !outcome.missingSecretBindings.isEmpty {
                Text("Missing API keys: \(outcome.missingProviderNames.joined(separator: ", "))")
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronWarning)
            }
            ForEach(outcome.errors, id: \.self) { error in
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronError)
            }
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }

    private var outcomeMetrics: [String] {
        [
            outcome.resultCount.map { "\($0) results" },
            outcome.sourceCount.map { "\($0) sources" },
            outcome.evidenceCount.map { "\($0) evidence" },
            outcome.claimCount.map { "\($0) claims" },
            outcome.supportedClaimCount.map { "\($0) supported" },
        ].compactMap { $0 }
    }
}
