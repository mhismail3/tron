import SwiftUI

struct EngineComponentCard: View {
    let component: EngineCoreComponentDTO

    private var color: Color {
        switch component.category {
        case "kernel": .tronEmerald
        case "protected_boundary": .tronPurple
        default: .tronCyan
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(component.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(WorkerConsolePresentation.displayLabel(component.category))
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(component.role)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .sectionFill(color, cornerRadius: 11, subtle: true, interactive: false)
    }

    private var symbol: String {
        switch component.id {
        case "model_agent_execution": "brain.head.profile"
        case "host_substrate": "terminal"
        case "durable_truth": "externaldrive.badge.checkmark"
        case "worker_runtime": "bolt.horizontal.circle"
        case "secret_observation_boundary": "key.viewfinder"
        case "authenticated_transport": "lock.shield"
        case "profile_provider_shell": "switch.2"
        case "core_change_guard": "arrow.triangle.branch"
        default: "square.stack.3d.up"
        }
    }
}

struct EngineSurfaceCard: View {
    let viewModel: WorkerConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    viewModel.autonomousWorkers ? "Live model surface" : "Model surface hidden",
                    systemImage: viewModel.autonomousWorkers ? "eye.circle.fill" : "eye.slash.circle"
                )
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(viewModel.autonomousWorkers ? .tronEmerald : .tronWarning)
                Spacer()
                if let revision = viewModel.catalogRevision {
                    Text("r\(revision)")
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            HStack(spacing: 0) {
                metric(viewModel.coreToolCount, "Fixed")
                divider
                metric(viewModel.projectedWorkerCount, "Projected")
                divider
                metric(viewModel.availableWorkerCount, "Available")
            }

            let projected = viewModel.availableWorkerTools.filter(\.projected)
            if !projected.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Worker tools on the next turn")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    ForEach(projected) { worker in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(worker.promoted ? Color.tronPurple : .tronEmerald)
                                .frame(width: 6, height: 6)
                            Text(worker.modelName)
                                .font(TronTypography.code(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(EngineDashboardPresentation.selectionReason(worker.selectionReason))
                                .font(TronTypography.sans(size: TronTypography.sizeSM))
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if let hash = viewModel.engineSnapshot?.surface.surfaceHash, !hash.isEmpty {
                Text("Surface \(WorkerConsolePresentation.compactIdentifier(hash, length: 12))")
                    .font(TronTypography.code(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextMuted)
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

struct EngineCoreToolCard: View {
    let tool: EngineSurfaceToolDTO

    private var color: Color {
        switch tool.primitiveGroup {
        case "host": .tronCyan
        case "core_change": .tronPurple
        default: .tronEmerald
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                metadata("Function", tool.functionId)
                metadata("Revision", "\(tool.functionRevision)")
                schema("Input schema", tool.inputSchema)
                if let output = tool.outputSchema {
                    schema("Output schema", output)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tool.exposed ? "function" : "function.slash")
                    .foregroundStyle(tool.exposed ? color : .tronTextMuted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.modelName)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                    Text(tool.description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(WorkerConsolePresentation.displayLabel(tool.effectClass))
                        Text(tool.risk.capitalized)
                        Text(tool.exposed ? "Exposed" : "Hidden")
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(tool.exposed ? color : .tronTextMuted)
                }
                Spacer(minLength: 0)
            }
        }
        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
        .tint(color)
        .padding(12)
        .sectionFill(color, cornerRadius: 11, subtle: true, interactive: false)
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
