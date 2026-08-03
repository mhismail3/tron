import SwiftUI

struct ToolInvocationGroupDetailSheet: View {
    let data: ToolInvocationGroupData

    @State private var selectedInvocation: ToolInvocationData?
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        switch data.displayStatus {
        case .error, .unavailable:
            return .tronError
        default:
            return .tronSuccess
        }
    }

    private var tint: TintedColors {
        TintedColors(accent: accent, colorScheme: colorScheme)
    }

    private var failedInvocations: [ToolInvocationData] {
        data.invocations.filter { $0.status == .error || $0.status == .unavailable }
    }

    private var activeInvocations: [ToolInvocationData] {
        data.invocations.filter { $0.status == .running || $0.status == .generating }
    }

    private var completedInvocations: [ToolInvocationData] {
        data.invocations.filter { invocation in
            !(failedInvocations.contains(where: { $0.id == invocation.id }) ||
              activeInvocations.contains(where: { $0.id == invocation.id }))
        }
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Tools",
            iconName: "square.stack.3d.up",
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                        .sheetSection()

                    if !failedInvocations.isEmpty {
                        invocationSection(
                            title: "Needs attention",
                            invocations: failedInvocations,
                            sectionAccent: .tronError
                        )
                        .sheetSection()
                    }

                    if !activeInvocations.isEmpty {
                        invocationSection(
                            title: "Still running",
                            invocations: activeInvocations,
                            sectionAccent: .tronBlue
                        )
                        .sheetSection()
                    }

                    if !completedInvocations.isEmpty {
                        invocationSection(
                            title: failedInvocations.isEmpty ? "Invocations" : "Completed",
                            invocations: completedInvocations,
                            sectionAccent: .tronSuccess
                        )
                        .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(item: $selectedInvocation) { invocation in
            ToolInvocationDetailSheet(data: invocation)
        }
    }

    private var summarySection: some View {
        ToolDetailSection(title: data.isActive ? "Current state" : "Outcome", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                Text(groupNarrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                ToolMetricStrip(
                    rows: [
                        ToolDisplayRow(label: "Used", value: "\(data.count)"),
                        ToolDisplayRow(label: "Finished", value: "\(data.completedCount)"),
                        ToolDisplayRow(label: "Failed", value: "\(data.failedCount)")
                    ],
                    tint: tint
                )
            }
        }
    }

    private var groupNarrative: String {
        if data.isActive {
            return "Tron is using \(data.count) tools in this batch. Completed calls will stay inspectable as the rest finish."
        }
        if data.failedCount > 0 {
            return "Tron used \(data.count) tools. \(data.failedCount) need attention and are listed first with safe failure details."
        }
        return "Tron used \(data.count) tools and all completed. Open any invocation for request, result, and evidence details."
    }

    private func invocationSection(
        title: String,
        invocations: [ToolInvocationData],
        sectionAccent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(TintedColors(accent: sectionAccent, colorScheme: colorScheme).heading)
                Spacer()
                Text("\(invocations.count)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .countBadge(sectionAccent)
            }

            VStack(spacing: 0) {
                ForEach(invocations.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                            .overlay(sectionAccent.opacity(colorScheme == .light ? 0.18 : 0.20))
                            .padding(.leading, 44)
                    }
                    invocationRow(invocations[index])
                }
            }
            .sectionFill(sectionAccent, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func invocationRow(_ invocation: ToolInvocationData) -> some View {
        let brief = ToolInvocationBriefPresentation(data: invocation)
        let rowAccent = ToolPresentation.statusColor(
            for: invocation.status,
            identity: invocation.identity,
            targetId: invocation.display.targetId
        )
        return Button {
            selectedInvocation = invocation
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: invocation.status.iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(rowAccent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(brief.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    if let qualifier = brief.subtitle {
                        Text(qualifier)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(invocation.formattedDuration ?? invocation.display.statusText)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(brief.title), \(invocation.display.statusText)")
    }
}
