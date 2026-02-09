import SwiftUI

@available(iOS 26.0, *)
struct MemoryDashboardDetailSheet: View {
    let entry: LedgerEntryDTO
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    metadataHeader
                        .padding(.horizontal)

                    if entry.input != nil || !entry.actions.isEmpty {
                        summarySection
                            .padding(.horizontal)
                    }

                    if !entry.decisions.isEmpty {
                        decisionsSection
                            .padding(.horizontal)
                    }

                    if !entry.lessons.isEmpty {
                        lessonsSection
                            .padding(.horizontal)
                    }

                    if !entry.insights.isEmpty {
                        insightsSection
                            .padding(.horizontal)
                    }

                    if !entry.files.isEmpty {
                        filesSection
                            .padding(.horizontal)
                    }

                    if !entry.tags.isEmpty {
                        tagsSection
                            .padding(.horizontal)
                    }

                    rawEntrySection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(entry.title ?? "Ledger Entry")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.purple)
    }

    // MARK: - Metadata Header

    private var metadataHeader: some View {
        HStack(spacing: 16) {
            if let model = entry.model {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    Text(formatModelDisplayName(model))
                        .font(TronTypography.codeSM)
                }
                .foregroundStyle(.tronTextMuted)
            }

            if let cost = entry.tokenCost,
               let input = cost.input,
               let output = cost.output {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    Text("\(formatTokens(input)) in / \(formatTokens(output)) out")
                        .font(TronTypography.codeSM)
                }
                .foregroundStyle(.tronTextMuted)
            }

            if let entryType = entry.entryType {
                Text(entryType)
                    .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(colorForType(entryType))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(colorForType(entryType).opacity(0.15))
                    .clipShape(Capsule())
            }

            Spacer()
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = entry.input {
                Text(input)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronTextPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !entry.actions.isEmpty {
                Divider()
                    .background(.purple.opacity(0.2))

                ForEach(Array(entry.actions.enumerated()), id: \.offset) { _, action in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.purple.opacity(0.6))
                            .padding(.top, 2)
                        Text(action)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .lineSpacing(3)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Decisions

    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decisions")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.purple.opacity(0.7))

            ForEach(Array(entry.decisions.enumerated()), id: \.offset) { _, decision in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.purple.opacity(0.6))
                            .padding(.top, 2)
                        Text(decision.choice)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                    }
                    Text(decision.reason)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Lessons

    private var lessonsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lessons")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.purple.opacity(0.7))

            ForEach(Array(entry.lessons.enumerated()), id: \.offset) { _, lesson in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.yellow.opacity(0.6))
                        .padding(.top, 2)
                    Text(lesson)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineSpacing(3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thinking Insights")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.purple.opacity(0.7))

            ForEach(Array(entry.insights.enumerated()), id: \.offset) { _, insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "brain")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.purple.opacity(0.6))
                        .padding(.top, 2)
                    Text(insight)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineSpacing(3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.purple.opacity(0.7))

            ForEach(Array(entry.files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 8) {
                    Text(file.op)
                        .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .bold))
                        .foregroundStyle(opColor(file.op))
                        .frame(width: 16)

                    Text(file.path)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(file.why)
                        .font(TronTypography.mono(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entry.tags, id: \.self) { tag in
                    Text(tag)
                        .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Raw Entry

    private var rawEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ledger Entry")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(prettyPrintEntry(entry))
                    .font(TronTypography.mono(size: 11))
                    .foregroundStyle(.tronTextSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Helpers

    private func prettyPrintEntry(_ entry: LedgerEntryDTO) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func colorForType(_ type: String) -> Color {
        switch type.lowercased() {
        case "feature": .green
        case "bugfix": .red
        case "refactor": .cyan
        case "docs": .blue
        case "config": .orange
        case "research": .yellow
        case "conversation": .purple
        default: .tronTextSecondary
        }
    }

    private func opColor(_ op: String) -> Color {
        switch op.uppercased() {
        case "C": .green
        case "M": .yellow
        case "D": .red
        default: .tronTextMuted
        }
    }
}
