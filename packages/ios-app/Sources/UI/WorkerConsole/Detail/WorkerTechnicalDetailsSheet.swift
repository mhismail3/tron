import SwiftUI

/// Bounded technical inspection presented on demand from the worker overview.
struct WorkerTechnicalDetailsSheet: View {
    @Bindable var viewModel: WorkerConsoleViewModel
    let worker: WorkerSummaryDTO
    let inspection: WorkerInspectResultDTO

    var body: some View {
        NavigationStack {
            ScrollView {
                identityAndRole
                    .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker Details", color: .tronInfo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronInfo)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronInfo)
    }

    private var identityAndRole: some View {
        let provenance = WorkerConsolePresentation.provenance(
            from: inspection.bundle["provenance"]
        )
        let architecture = viewModel.selectedWorkerArchitecture
        let callers = architecture.map { viewModel.callers(of: $0.workerId) } ?? []
        let boundaries = architecture.map {
            $0.clientActions + $0.clientDeliveries
        } ?? []
        let workerCalls = architecture?.calls
            .filter { $0.targetWorkerId != nil }
            .map(\.label) ?? []
        let engineTools = architecture?.calls
            .filter { $0.targetWorkerId == nil }
            .map(\.label) ?? []

        return WorkerConsoleSection(
            title: "Identity & role",
            detail: "Technical ownership, execution, provenance, and worker-system relationships.",
            accent: .tronInfo
        ) {
            VStack(spacing: 0) {
                WorkerMetadataRow(label: "Tool", value: worker.toolName, isCode: true)
                WorkerMetadataDivider()
                if let architecture {
                    WorkerMetadataRow(
                        label: "Agent access",
                        value: architecture.modelExposure == "direct"
                            ? "Direct chat tool"
                            : "Internal specialist"
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Execution",
                        value: executionLabel(for: architecture)
                    )
                } else {
                    WorkerMetadataRow(
                        label: "Runner",
                        value: WorkerConsolePresentation.runnerLabel(worker.runnerKind)
                    )
                }
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Active version",
                    value: WorkerConsolePresentation.compactIdentifier(worker.activeVersion),
                    isCode: true
                )
                if let updated = WorkerConsolePresentation.timestamp(worker.updatedAt) {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(label: "Updated", value: updated)
                }
                if !provenance.isEmpty {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: provenance.count == 1 ? "Source" : "Sources",
                        value: provenance.map(\.fullLabel).joined(separator: ", ")
                    )
                }
                if let architecture {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Suite",
                        value: architecture.presentation.suiteId.map(
                            WorkerConsolePresentation.displayLabel
                        ) ?? "Independent"
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Role",
                        value: architecture.presentation.componentRole.map(
                            WorkerConsolePresentation.displayLabel
                        ) ?? "Primary domain owner"
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Engine hooks",
                        value: readableList(architecture.engineHooks)
                    )
                    if !boundaries.isEmpty {
                        WorkerMetadataDivider()
                        WorkerMetadataRow(
                            label: "Native boundaries",
                            value: readableList(boundaries)
                        )
                    }
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Calls workers",
                        value: readableList(workerCalls)
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Called by workers",
                        value: readableList(callers.map(\.name))
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Uses engine tools",
                        value: readableList(engineTools)
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Worker ID",
                        value: architecture.workerId,
                        isCode: true
                    )
                }
            }
        }
    }

    private func executionLabel(for architecture: WorkerArchitectureNodeDTO) -> String {
        let runner = WorkerConsolePresentation.runnerLabel(architecture.runnerKind)
        guard let model = architecture.runnerModel, !model.isEmpty else { return runner }
        return "\(runner) · \(model)"
    }

    private func readableList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "None" }
        return values
            .map(WorkerConsolePresentation.displayLabel)
            .joined(separator: ", ")
    }
}
