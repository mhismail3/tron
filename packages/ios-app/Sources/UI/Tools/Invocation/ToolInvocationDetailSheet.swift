import SwiftUI

struct ToolInvocationDetailSheet: View {
    let data: ToolInvocationData

    @Environment(\.colorScheme) private var colorScheme
    @State private var showTechnicalDetails = false

    private var display: ToolInvocationDisplayModel { data.display }
    private var evidence: ToolEvidencePresentation { ToolEvidencePresentation(data: data) }
    private var brief: ToolInvocationBriefPresentation {
        ToolInvocationBriefPresentation(data: data)
    }
    private var surface: ToolInvocationSurface {
        ToolInvocationSurface(identity: data.identity)
    }
    private var structuredRequest: ToolStructuredDocument? {
        ToolStructuredDocument.request(from: data)
    }
    private var structuredResult: ToolStructuredDocument? {
        ToolStructuredDocument.result(from: data)
    }
    private var isActive: Bool {
        data.status == .generating || data.status == .running
    }
    private var showsLiveActivity: Bool {
        !surface.isWorker && isActive
    }
    private var accent: Color {
        ToolPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }
    private var hasTechnicalDetails: Bool {
        !brief.evidenceRows.isEmpty
            || !brief.technicalRows.isEmpty
            || brief.rawRequest != nil
            || brief.rawResult != nil
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: evidence.title,
            iconName: ToolPresentation.symbol(for: data.identity, targetId: display.targetId),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if surface.isWorker {
                        WorkerToolRunGraphView(
                            invocationId: brief.backgroundInvocationId,
                            modelToolInvocationId: data.id
                        )
                        .sheetSection()
                    } else if showsLiveActivity {
                        progressSection
                            .sheetSection()
                    }

                    if !surface.isWorker {
                        whatHappenedSection
                            .sheetSection()
                    }

                    if let issue = brief.issue {
                        issueSection(issue)
                            .sheetSection()
                    }

                    if !surface.isWorker,
                       !brief.resultRows.isEmpty || brief.resultBody != nil || structuredResult != nil {
                        resultSection
                            .sheetSection()
                    }

                    if !surface.isWorker,
                       !brief.requestRows.isEmpty || structuredRequest != nil {
                        requestSection
                            .sheetSection()
                    }

                    if !data.artifacts.isEmpty {
                        artifactsSection
                            .sheetSection()
                    }

                    if hasTechnicalDetails {
                        technicalDetailsSection
                            .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showTechnicalDetails) {
            ToolTechnicalDetailsSheet(
                title: evidence.title,
                evidenceRows: brief.evidenceRows,
                technicalRows: brief.technicalRows,
                rawRequest: brief.rawRequest,
                rawResult: brief.rawResult,
                accent: .tronSlate
            )
        }
    }

    private var progressSection: some View {
        ToolDetailSection(title: "Live activity", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentProgressMessage)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(progressSupportText)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(tint.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    TimelineView(.periodic(from: data.startedAt ?? data.generatedAt ?? Date(), by: 0.25)) { context in
                        Text(data.formattedElapsed(at: context.date) ?? "Running")
                            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(tint.accent)
                            .monospacedDigit()
                    }
                }

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .tint(tint.accent)
                        .accessibilityLabel("Worker progress")
                        .accessibilityValue("\(Int((progressFraction * 100).rounded())) percent")
                } else {
                    ProgressView()
                        .tint(tint.accent)
                        .controlSize(.small)
                }

                ToolProgressJourneyView(
                    steps: display.progressSteps,
                    activity: data.logs,
                    isActive: isActive || brief.isBackgroundHandoff,
                    tint: tint
                )
            }
        }
    }

    private var currentProgressMessage: String {
        data.progressMessage?.nilIfEmpty
            ?? (brief.isBackgroundHandoff ? "Continuing in the background" : nil)
            ?? (surface.isAgentWorker ? "Agent worker is running" : "\(brief.title) is running")
    }

    private var progressSupportText: String {
        if brief.isBackgroundHandoff {
            return "The foreground turn has been released. Session Context owns current status, nested work, cancellation, and the eventual result."
        }
        if surface.isAgentWorker {
            return "Current steps and streamed output update here as the child agent reports them."
        }
        if surface.isWorker {
            return "Durable worker status and output update here from the canonical invocation stream."
        }
        return "Execution status updates here from the canonical tool lifecycle."
    }

    private var progressFraction: Double? {
        guard let percent = data.progressPercent, percent.isFinite else { return nil }
        let fraction = percent > 1 ? percent / 100 : percent
        return min(max(fraction, 0), 1)
    }

    private var whatHappenedSection: some View {
        ToolDetailSection(
            title: showsLiveActivity ? "Current state" : "Outcome",
            accent: accent,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(brief.narrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                ToolMetricStrip(rows: brief.factRows, tint: tint)
            }
        }
    }

    private func issueSection(_ issue: ToolInvocationBriefPresentation.Issue) -> some View {
        let issueTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        return ToolDetailSection(title: "Needs attention", accent: .tronError, tint: issueTint) {
            VStack(alignment: .leading, spacing: 12) {
                Text(issue.message)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(issueTint.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let nextStep = issue.nextStep {
                    Label(nextStep, systemImage: "arrow.triangle.2.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                        .foregroundStyle(issueTint.accent)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !issue.rows.isEmpty {
                    ToolMetricStrip(rows: issue.rows, tint: issueTint)
                }
            }
        }
    }

    private var resultSection: some View {
        ToolDetailSection(title: surface.resultTitle, accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                if !brief.resultRows.isEmpty {
                    ToolMetricStrip(rows: brief.resultRows, tint: tint)
                }
                if let structuredResult {
                    ToolStructuredDocumentView(document: structuredResult, tint: tint)
                } else if let body = brief.resultBody {
                    ToolReadableResultText(text: body, tint: tint)
                }
            }
        }
    }

    private var requestSection: some View {
        ToolDetailSection(title: "Request", accent: accent, tint: tint) {
            if surface.isWorker, let structuredRequest {
                ToolStructuredDocumentView(document: structuredRequest, tint: tint)
            } else if !brief.requestRows.isEmpty {
                ToolInlineRows(rows: brief.requestRows, tint: tint)
            } else if let structuredRequest {
                ToolStructuredDocumentView(document: structuredRequest, tint: tint)
            }
        }
    }

    private var artifactsSection: some View {
        ToolDetailSection(title: "Artifacts", accent: .tronPurple, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data.artifacts, id: \.id) { artifact in
                    ToolArtifactRow(artifact: artifact)
                }
            }
        }
    }

    private var technicalDetailsSection: some View {
        let evidenceTint = TintedColors(accent: .tronSlate, colorScheme: colorScheme)
        return ToolDetailSection(title: "Technical details", accent: .tronSlate, tint: evidenceTint) {
            Button {
                showTechnicalDetails = true
            } label: {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(evidenceTint.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open technical details")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Identifiers, protocol references, and raw request or result payloads.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ToolTechnicalDetailsSheet: View {
    let title: String
    let evidenceRows: [ToolDisplayRow]
    let technicalRows: [ToolDisplayRow]
    let rawRequest: String?
    let rawResult: String?
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !evidenceRows.isEmpty {
                        ToolDetailSection(
                            title: "Run identifiers",
                            accent: accent,
                            tint: tint
                        ) {
                            ToolInlineRows(rows: evidenceRows, tint: tint)
                        }
                        .sheetSection()
                    }

                    if !technicalRows.isEmpty {
                        ToolDetailSection(
                            title: "Protocol references",
                            accent: accent,
                            tint: tint
                        ) {
                            ToolInlineRows(rows: technicalRows, tint: tint)
                        }
                        .sheetSection()
                    }

                    if rawRequest != nil || rawResult != nil {
                        ToolDetailSection(
                            title: "Raw protocol",
                            accent: accent,
                            tint: tint
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let rawRequest {
                                    ToolRawDetailLink(
                                        title: "Raw request",
                                        text: rawRequest,
                                        tint: tint
                                    )
                                }
                                if let rawResult {
                                    ToolRawDetailLink(
                                        title: "Raw result",
                                        text: rawResult,
                                        tint: tint
                                    )
                                }
                            }
                        }
                        .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "\(title) Details", color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }

    @Environment(\.colorScheme) private var colorScheme
    private var tint: TintedColors {
        TintedColors(accent: accent, colorScheme: colorScheme)
    }
}

struct ToolMetricStrip: View {
    let rows: [ToolDisplayRow]
    let tint: TintedColors

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.18))
                        .padding(.vertical, 2)
                }
                ToolMetricStripItem(row: rows[index], tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

private struct ToolMetricStripItem: View {
    let row: ToolDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
                .lineLimit(1)
            Text(row.value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 10)
        .padding(.leading, 10)
    }
}

private struct ToolInlineRows: View {
    let rows: [ToolDisplayRow]
    let tint: TintedColors

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.14))
                }
                ToolInlineRow(row: rows[index], tint: tint)
            }
        }
    }
}

private struct ToolInlineRow: View {
    let row: ToolDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
            Text(row.value)
                .font(row.isTechnical ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular) : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(row.isTechnical ? tint.body : .tronTextPrimary)
                .lineLimit(row.isTechnical ? 3 : 4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }
}

struct ToolInvocationResultView: View {
    let result: ToolInvocationResultData

    var body: some View {
        ToolResultRenderer(
            content: result.content,
            details: result.details,
            identity: result.identity
        )
    }
}
