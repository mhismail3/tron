import SwiftUI

struct WorkerSystemSheet: View {
    let workers: [WorkerArchitectureNodeDTO]
    let fixedToolCount: UInt64

    @State private var selectedWorker: WorkerArchitectureNodeDTO?

    private var calledBy: [String: [WorkerArchitectureNodeDTO]] {
        var result: [String: [WorkerArchitectureNodeDTO]] = [:]
        for worker in workers {
            for edge in worker.calls {
                guard let target = edge.targetWorkerId else { continue }
                result[target, default: []].append(worker)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    architectureSummary
                    workerGroup(
                        title: "Direct domain workers",
                        workers: workers.filter { $0.modelExposure == "direct" }
                    )
                    workerGroup(
                        title: "Internal policy & specialists",
                        workers: workers.filter { $0.modelExposure == "internal" }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker System", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
            .sheet(item: $selectedWorker) { worker in
                WorkerSystemNodeSheet(worker: worker, calledBy: calledBy[worker.workerId] ?? [])
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronCyan)
    }

    private var architectureSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fixed engine custody")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(
                "\(fixedToolCount) fixed request tools sit above one durable worker kernel. Hooks delegate semantic policy; authenticated client boundaries retain native permission and transport custody."
            )
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private func workerGroup(title: String, workers: [WorkerArchitectureNodeDTO]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsSectionHeader(title: title, bottomPadding: 4)
            ForEach(workers.sorted { $0.name < $1.name }) { worker in
                Button {
                    selectedWorker = worker
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: worker.runnerKind == "agent"
                            ? "sparkles"
                            : "gearshape.2")
                            .foregroundStyle(worker.modelExposure == "direct"
                                ? .tronEmerald
                                : .tronPurple)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(worker.name)
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeBodySM,
                                    weight: .semibold
                                ))
                                .foregroundStyle(.tronTextPrimary)
                            Text(worker.description)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tronTextMuted)
                    }
                    .padding(13)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .sectionFill(
                    worker.modelExposure == "direct" ? .tronEmerald : .tronPurple,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: true
                )
            }
        }
    }
}

private struct WorkerSystemNodeSheet: View {
    let worker: WorkerArchitectureNodeDTO
    let calledBy: [WorkerArchitectureNodeDTO]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(worker.description)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                        HStack {
                            badge(worker.modelExposure, color: .tronEmerald)
                            badge(worker.runnerKind, color: .tronPurple)
                            badge(worker.health, color: .tronCyan)
                        }
                    }
                    .padding(14)
                    .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)

                    SettingsSectionHeader(title: "Boundaries & relationships", bottomPadding: 4)
                    VStack(spacing: 0) {
                        metadata("Hooks", worker.engineHooks.joined(separator: ", "))
                        Divider().opacity(0.35)
                        metadata(
                            "Client",
                            (worker.clientActions + worker.clientDeliveries)
                                .joined(separator: ", ")
                        )
                        Divider().opacity(0.35)
                        metadata(
                            "Calls",
                            worker.calls.map(\.label).joined(separator: ", ")
                        )
                        Divider().opacity(0.35)
                        metadata(
                            "Called by",
                            calledBy.map(\.name).joined(separator: ", ")
                        )
                    }
                    .padding(.horizontal, 13)
                    .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)

                    SettingsSectionHeader(title: "Identity", bottomPadding: 4)
                    VStack(spacing: 0) {
                        metadata("Worker", worker.workerId, code: true)
                        Divider().opacity(0.35)
                        metadata("Version", worker.activeVersion, code: true)
                        Divider().opacity(0.35)
                        metadata(
                            "Suite",
                            worker.presentation.suiteId ?? "Independent"
                        )
                        Divider().opacity(0.35)
                        metadata(
                            "Role",
                            worker.presentation.componentRole ?? "Primary domain owner"
                        )
                    }
                    .padding(.horizontal, 13)
                    .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: worker.name, color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronCyan)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(WorkerConsolePresentation.displayLabel(text))
            .font(TronTypography.pillValue)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func metadata(_ label: String, _ value: String, code: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            Spacer()
            Text(value.isEmpty ? "None" : value)
                .font(code
                    ? .system(size: TronTypography.sizeCaption, design: .monospaced)
                    : TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
    }
}
