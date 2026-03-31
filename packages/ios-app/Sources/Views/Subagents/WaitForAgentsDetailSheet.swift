import SwiftUI

// MARK: - WaitForAgents Detail Sheet

@available(iOS 26.0, *)
struct WaitForAgentsDetailSheet: View {
    let data: WaitForAgentsChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronTeal, colorScheme: colorScheme)
    }

    private var accent: Color {
        switch data.status {
        case .waiting: .tronTeal
        case .completed: .tronTeal
        case .timedOut: .tronAmber
        case .error: .tronError
        }
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Wait For Agents",
            iconName: "person.2.circle",
            accent: accent
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                agentListSection
                    .padding(.horizontal)
                statusRow
                    .padding(.horizontal)

                switch data.status {
                case .waiting:
                    waitingSection
                        .padding(.horizontal)
                case .completed:
                    if let result = data.fullResult, !result.isEmpty {
                        resultSection(result)
                            .padding(.horizontal)
                    } else {
                        ToolEmptyState(
                            title: "Results",
                            icon: "checkmark.circle",
                            message: "All agents completed",
                            accent: .tronTeal,
                            tint: tint
                        )
                        .padding(.horizontal)
                    }
                case .timedOut:
                    timeoutSection
                        .padding(.horizontal)
                case .error:
                    if let error = data.errorMessage {
                        errorSection(error)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Agent List Section

    private var agentListSection: some View {
        ToolDetailSection(title: "Agents", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(data.agentCount) agent\(data.agentCount == 1 ? "" : "s")")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(tint.name)

                        Text("Mode: \(data.mode == .all ? "wait for all" : "wait for any")")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(tint.secondary)
                    }

                    Spacer()
                }

                ForEach(Array(data.sessionIds.enumerated()), id: \.offset) { index, sessionId in
                    HStack(spacing: 8) {
                        let isCompleted = index < data.completedCount
                        Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(isCompleted ? .tronSuccess : tint.subtle)

                        Text(abbreviateSessionId(sessionId))
                            .font(TronTypography.codeContent)
                            .foregroundStyle(tint.body)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(
            status: data.status == .error ? .error : (data.status == .waiting ? .running : .success),
            durationMs: data.durationMs
        ) {
            ToolInfoPill(
                icon: "person.2",
                label: "\(data.completedCount)/\(data.agentCount) done",
                color: accent
            )
            if data.mode == .all {
                ToolInfoPill(icon: "arrow.triangle.merge", label: "All", color: .tronTeal)
            } else {
                ToolInfoPill(icon: "arrow.triangle.branch", label: "Any", color: .tronTeal)
            }
        }
    }

    // MARK: - Waiting Section

    private var waitingSection: some View {
        ToolRunningSpinner(
            title: "Status",
            accent: .tronTeal,
            tint: tint,
            actionText: data.agentCount > 1
                ? "Waiting for \(data.agentCount - data.completedCount) agent\(data.agentCount - data.completedCount == 1 ? "" : "s")..."
                : "Waiting for agent..."
        )
    }

    // MARK: - Result Section

    private func resultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: result, accent: .tronTeal)
            }

            let entries = parseResultEntries(result)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(entry.color)
                            .frame(width: 16)

                        Text(entry.text)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(tint.body)
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(.tronTeal)
        }
    }

    // MARK: - Timeout Section

    private var timeoutSection: some View {
        let classification = ErrorClassification(
            icon: "clock.badge.exclamationmark",
            title: "Wait Timed Out",
            code: nil,
            suggestion: "\(data.completedCount) of \(data.agentCount) agents completed before timeout."
        )
        return ToolClassifiedErrorSection(
            errorMessage: data.errorMessage ?? "The wait exceeded the timeout limit.",
            classification: classification,
            colorScheme: colorScheme
        ) { EmptyView() }
    }

    // MARK: - Error Section

    private func errorSection(_ error: String) -> some View {
        let classification = ErrorClassification(
            icon: "xmark.circle.fill",
            title: "Wait Failed",
            code: nil,
            suggestion: "One or more agents encountered an error."
        )
        return ToolClassifiedErrorSection(
            errorMessage: error,
            classification: classification,
            colorScheme: colorScheme
        ) { EmptyView() }
    }

    // MARK: - Helpers

    private func abbreviateSessionId(_ id: String) -> String {
        if id.hasPrefix("sess_") {
            let trimmed = String(id.dropFirst(5))
            return "sess_\(trimmed.prefix(8))...\(trimmed.suffix(4))"
        }
        if id.count > 20 {
            return "\(id.prefix(12))...\(id.suffix(4))"
        }
        return id
    }

    private struct ResultEntry {
        let text: String
        let icon: String
        let color: Color
    }

    private func parseResultEntries(_ result: String) -> [ResultEntry] {
        result.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.contains("[completed]") {
                    return ResultEntry(text: line, icon: "checkmark.circle.fill", color: .tronSuccess)
                } else if line.contains("[error]") || line.contains("[failed]") {
                    return ResultEntry(text: line, icon: "xmark.circle.fill", color: .tronError)
                } else if line.contains("[timed_out]") {
                    return ResultEntry(text: line, icon: "clock.badge.exclamationmark", color: .tronAmber)
                } else {
                    return ResultEntry(text: line, icon: "arrow.right.circle", color: .tronTeal)
                }
            }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("WaitForAgents - Completed") {
    WaitForAgentsDetailSheet(
        data: WaitForAgentsChipData(
            toolCallId: "call_w1",
            sessionIds: [
                "sess_019d410b-9329-7e12-99c4-167dca468085",
                "sess_019d410b-a1b2-c3d4-e5f6-778899aabbcc"
            ],
            mode: .all,
            status: .completed,
            completedCount: 2,
            durationMs: 1800,
            resultPreview: "2 agents completed",
            fullResult: "[completed] sess_019d410b-9329-7e12-99c4-167dca468085\n[completed] sess_019d410b-a1b2-c3d4-e5f6-778899aabbcc"
        )
    )
}

@available(iOS 26.0, *)
#Preview("WaitForAgents - Waiting") {
    WaitForAgentsDetailSheet(
        data: WaitForAgentsChipData(
            toolCallId: "call_w2",
            sessionIds: ["sess_abc123"],
            mode: .any,
            status: .waiting,
            completedCount: 0,
            durationMs: nil
        )
    )
}

@available(iOS 26.0, *)
#Preview("WaitForAgents - Timed Out") {
    WaitForAgentsDetailSheet(
        data: WaitForAgentsChipData(
            toolCallId: "call_w3",
            sessionIds: [
                "sess_019d410b-9329-7e12-99c4-167dca468085",
                "sess_019d410b-a1b2-c3d4-e5f6-778899aabbcc"
            ],
            mode: .all,
            status: .timedOut,
            completedCount: 1,
            durationMs: 30000,
            errorMessage: "Wait timed out after 30s"
        )
    )
}
#endif
