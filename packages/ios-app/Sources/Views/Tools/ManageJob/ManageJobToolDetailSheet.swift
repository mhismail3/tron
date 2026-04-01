import SwiftUI

// MARK: - ManageJob Tool Detail Sheet

/// Detail sheet for the ManageJob tool.
/// Shows the action performed (start, cancel, list, status) with relevant
/// arguments and the plain-text result.
@available(iOS 26.0, *)
struct ManageJobToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronSlate, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var action: String {
        ToolArgumentParser.string("action", from: data.arguments) ?? "list"
    }

    private var jobId: String? {
        ToolArgumentParser.string("jobId", from: data.arguments)
    }

    private var command: String? {
        ToolArgumentParser.string("command", from: data.arguments)
    }

    // MARK: - Body

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Jobs",
            iconName: "gearshape.2",
            accent: .tronSlate
        ) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    statusRow
                        .sheetSection()
                    actionSection
                        .sheetSection()
                    contentSection
                        .sheetSection()
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            ToolInfoPill(
                icon: actionIcon,
                label: action.capitalized,
                color: .tronSlate
            )
        }
    }

    private var actionIcon: String {
        switch action {
        case "start": return "play.circle"
        case "cancel": return "stop.circle"
        case "status": return "info.circle"
        default: return "list.bullet"
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        ToolDetailSection(title: "Action", accent: .tronSlate, tint: tint) {
            switch action {
            case "start":
                if let command {
                    Text(command)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                } else {
                    Text("Start job")
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                }
            case "cancel", "status":
                if let jobId {
                    Text("\(action.capitalized) job \(jobId)")
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                }
            default:
                Text("List all jobs")
                    .font(TronTypography.codeContent)
                    .foregroundStyle(tint.body)
            }
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch data.status {
        case .running:
            ToolRunningSpinner(
                title: "Result",
                accent: .tronSlate,
                tint: tint,
                actionText: "Running \(action)..."
            )
        case .success, .error:
            if let result = data.result, !result.isEmpty {
                ToolDetailSection(
                    title: "Result",
                    accent: .tronSlate,
                    tint: tint,
                    trailing: ToolCopyButton(content: result, accent: .tronSlate)
                ) {
                    Text(result)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                }
            }
        }
    }
}
