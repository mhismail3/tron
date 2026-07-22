import SwiftUI

struct EngineSurfaceCard: View {
    let viewModel: WorkerConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    "Available tools",
                    systemImage: "wrench.and.screwdriver.fill"
                )
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronEmerald)
            }

            HStack(spacing: 0) {
                metric(viewModel.coreToolCount, "Fixed")
                divider
                metric(viewModel.availableWorkerCount, "Workers")
                divider
                metric(viewModel.coreToolCount + viewModel.availableWorkerCount, "Total")
            }

            Text("Fixed tools are always present. Every healthy enabled worker publishes a typed tool, and agents select the relevant worker set for each turn.")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !viewModel.activeEngineHooks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Worker-owned engine policy")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    ForEach(viewModel.activeEngineHooks) { owner in
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                                .foregroundStyle(.tronPurple)
                            Text(WorkerConsolePresentation.displayLabel(owner.hook))
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronTextPrimary)
                            Spacer()
                            Text(owner.workerId)
                                .font(TronTypography.code(size: TronTypography.sizeSM))
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }

        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Color.tronBorder.opacity(0.7)).frame(width: 1, height: 28)
    }
}

struct EngineCoreSection: View {
    let group: String
    let tools: [EngineSurfaceToolDTO]
    let onSelect: (EngineSurfaceToolDTO) -> Void

    private var color: Color {
        switch group {
        case "host": .tronCyan
        case "core_change": .tronPurple
        default: .tronEmerald
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WorkerConsoleSectionHeader(
                title: EngineDashboardPresentation.groupTitle(group),
                detail: EngineDashboardPresentation.groupDetail(group, count: tools.count)
            )

            LazyVStack(spacing: 8) {
                ForEach(tools) { tool in
                    Button {
                        onSelect(tool)
                    } label: {
                        EngineCoreToolRow(tool: tool, color: color)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct EngineCoreToolRow: View {
    let tool: EngineSurfaceToolDTO
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "function")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)

            Text(EngineDashboardPresentation.toolTitle(tool.modelName))
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: true)
        .contentShape(Rectangle())
    }
}

struct EngineCoreToolDetailSheet: View {
    let tool: EngineSurfaceToolDTO

    private var color: Color {
        switch tool.primitiveGroup {
        case "host": .tronCyan
        case "core_change": .tronPurple
        default: .tronEmerald
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tool.description)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            badge(WorkerConsolePresentation.displayLabel(tool.effectClass))
                            badge(tool.risk.capitalized)
                            badge(tool.exposed ? "Model visible" : "Internal")
                        }
                    }
                    .padding(14)
                    .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)

                    detailSection(title: "Identity") {
                        metadata("Tool name", tool.modelName)
                        metadata("Function", tool.functionId)
                        metadata("Owner", tool.ownerWorker)
                        metadata("Revision", "\(tool.functionRevision)")
                    }

                    detailSection(title: "Contract") {
                        schema("Input", tool.inputSchema)
                        if let output = tool.outputSchema {
                            schema("Output", output)
                        }
                    }
                }
                .padding(18)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: EngineDashboardPresentation.toolTitle(tool.modelName),
                        color: color
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: color)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(color)
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
        }
    }

    private func schema(_ label: String, _ value: AnyCodable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(WorkerConsoleViewModel.prettyJSON(value))
                    .font(TronTypography.code(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}
