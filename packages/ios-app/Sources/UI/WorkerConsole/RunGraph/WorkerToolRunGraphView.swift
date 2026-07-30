import Foundation
import SwiftUI

/// Generic controls for the authoritative durable worker state.
///
/// Actions mutate the durable invocation through the worker-kernel repository;
/// they never create client-owned execution state.
struct WorkerRunActionBar: View {
    let graph: WorkerRunGraphDTO
    let isMutating: Bool
    let detach: () -> Void
    let awaitResult: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    private var hasActions: Bool {
        WorkerRunGraphPresentation.canDetach(status: graph.status, mode: graph.mode)
            || WorkerRunGraphPresentation.canAwait(status: graph.status, mode: graph.mode)
            || WorkerRunGraphPresentation.canCancel(status: graph.status)
            || WorkerRunGraphPresentation.canRetry(status: graph.status)
    }

    var body: some View {
        if hasActions {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if WorkerRunGraphPresentation.canDetach(status: graph.status, mode: graph.mode) {
                        action("Continue in background", symbol: "arrow.up.forward.circle", color: .tronCyan, detach)
                    }
                    if WorkerRunGraphPresentation.canAwait(status: graph.status, mode: graph.mode) {
                        action("Await", symbol: "hourglass", color: .tronPurple, awaitResult)
                    }
                    if WorkerRunGraphPresentation.canCancel(status: graph.status) {
                        action("Cancel", symbol: "stop.fill", color: .tronError, cancel)
                    }
                    if WorkerRunGraphPresentation.canRetry(status: graph.status) {
                        action("Retry", symbol: "arrow.clockwise", color: .tronWarning, retry)
                    }
                }
            }
            .disabled(isMutating)
            .accessibilityIdentifier("worker-run-actions")
        }
    }

    private func action(
        _ title: String,
        symbol: String,
        color: Color,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .foregroundStyle(color)
    }
}

/// Authoritative durable worker projection embedded in a chat tool sheet.
/// The model-tool association is persisted at admission, so this works before
/// a direct worker tool has produced a terminal result or background receipt.
struct WorkerToolRunGraphView: View {
    let invocationId: String?
    let modelToolInvocationId: String

    @Environment(\.dependencies) private var dependencies
    @State private var graph: WorkerRunGraphDTO?
    @State private var isMutating = false
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var refreshRevision = 0
    @State private var selectedResult: WorkerResultSelection?
    @State private var showRunTree = false
    @State private var showTimeline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let graph {
                WorkerRunGraphSummaryView(graph: graph)

                WorkerRunDetailLinksView(
                    graph: graph,
                    openTree: { showRunTree = true },
                    openTimeline: { showTimeline = true }
                )

                WorkerRunTerminalResultView(graph: graph) {
                    selectedResult = WorkerResultSelection(
                        invocationId: graph.requestedInvocationId
                    )
                }
                WorkerRunDeclarativePresentationView(
                    graph: graph,
                    repository: dependencies.workerKernelRepository
                )

                WorkerRunActionBar(
                    graph: graph,
                    isMutating: isMutating,
                    detach: { mutate(.detach) },
                    awaitResult: { mutate(.awaitResult) },
                    cancel: { confirmCancel = true },
                    retry: { mutate(.retry) }
                )
            } else if let error {
                WorkerConsoleErrorBanner(message: error)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading durable worker state…")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
        .task(
            id: "\(invocationId ?? ""):\(modelToolInvocationId):\(refreshRevision):\(isPresentingChildSheet)"
        ) {
            guard !isPresentingChildSheet else { return }
            await observe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
            if !isPresentingChildSheet,
               WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(
                status: graph?.status
               ) {
                refreshRevision += 1
            }
        }
        .sheet(isPresented: $showRunTree) {
            if let graph {
                WorkerRunTreeSheet(graph: graph)
            }
        }
        .sheet(isPresented: $showTimeline) {
            if let graph {
                WorkerRunTimelineSheet(graph: graph)
            }
        }
        .sheet(item: $selectedResult) { selection in
            WorkerResultInspectorSheet(
                invocationId: selection.invocationId,
                repository: dependencies.workerKernelRepository
            )
        }
        .confirmationDialog(
            "Cancel this worker run?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel run", role: .destructive) { mutate(.cancel) }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Only this invocation and its causal descendants will stop.")
        }
        .accessibilityIdentifier("worker-tool-authoritative-graph")
    }

    private var isPresentingChildSheet: Bool {
        selectedResult != nil || showRunTree || showTimeline
    }

    private func observe() async {
        repeat {
            await refresh()
            guard !Task.isCancelled else {
                return
            }
            if let graph,
               !WorkerRunGraphPresentation.isActive(status: graph.status) {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        } while !Task.isCancelled
    }

    private func refresh() async {
        do {
            let page = try await dependencies.workerKernelRepository.workerRunGraph(
                invocationId: invocationId,
                modelToolInvocationId: invocationId == nil ? modelToolInvocationId : nil
            )
            graph = page.graphs?.first
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private enum Mutation {
        case detach
        case awaitResult
        case cancel
        case retry
    }

    private func mutate(_ mutation: Mutation) {
        guard !isMutating, let targetId = graph?.requestedInvocationId else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                switch mutation {
                case .detach:
                    _ = try await dependencies.workerKernelRepository.detachWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("detach-worker")
                    )
                case .awaitResult:
                    _ = try await dependencies.workerKernelRepository.awaitWorkerInvocation(
                        invocationId: targetId,
                        timeoutSeconds: 10
                    )
                case .cancel:
                    _ = try await dependencies.workerKernelRepository.cancelWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("cancel-worker")
                    )
                case .retry:
                    _ = try await dependencies.workerKernelRepository.retryWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("retry-worker")
                    )
                }
                error = nil
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
