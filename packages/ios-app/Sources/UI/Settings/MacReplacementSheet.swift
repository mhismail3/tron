import SwiftUI
import TronMobileCore

/// Presentation of one Mac replacement journal (#984): which path ran and why,
/// each step with its timing, the exact failure and log path, the rollback,
/// and the workers it stopped with an in-place Resume.
enum MacReplacementPresentation {
    static func stepIcon(_ step: MacReplacementStep) -> String {
        switch step.state {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        case "running": return "circle.dotted"
        default: return "circle"
        }
    }

    static func stepAccent(_ step: MacReplacementStep) -> Color {
        switch step.state {
        case "done": return .tronEmerald
        case "failed": return .tronError
        case "running": return .tronAmber
        default: return .tronTextMuted
        }
    }

    static func stepDetail(_ step: MacReplacementStep) -> String? {
        let duration = step.durationSeconds.map { formatDuration($0) }
        let parts = [step.detail, duration].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? (step.state == "pending" ? "Waiting" : nil) : parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    static func stateTitle(_ operation: MacReplacementOperation) -> String {
        switch operation.state {
        case "succeeded": return "Replaced"
        case "failed": return "Failed"
        case "rolled-back": return "Rolled back"
        case "rollback-failed": return "Rollback failed"
        case "queued": return "Starting"
        default:
            let index = operation.steps.firstIndex { $0.name == operation.currentStep }.map { $0 + 1 } ?? 0
            return "Step \(index) of \(operation.steps.count)"
        }
    }

    static func stateAccent(_ operation: MacReplacementOperation) -> Color {
        switch operation.state {
        case "succeeded": return .tronEmerald
        case "failed", "rollback-failed": return .tronError
        case "rolled-back": return .tronAmber
        default: return .tronAmber
        }
    }

    /// The plan's reason without the path title the row already shows.
    static func reasonDetail(_ reason: String) -> String {
        for prefix in ["Full signed build: ", "Quick rebuild: "] where reason.hasPrefix(prefix) {
            let rest = reason.dropFirst(prefix.count)
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return reason
    }

    static func pathTitle(_ path: String) -> String {
        path == "quick" ? "Quick rebuild" : path == "full" ? "Full signed build" : "Up to date"
    }

    static func workerDetail(_ worker: MacReplacementWorker) -> String {
        switch worker.state {
        case "resumable": return "Stopped and preserved"
        case "resumed": return "Resumed in place"
        case "stopping": return "Stopping"
        default: return "Home is unavailable"
        }
    }
}

struct MacReplacementSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    /// The focused server whose journal this sheet follows; nil renders a
    /// fixed journal (the hosted accessibility fixture) without reading.
    let profile: GatewayProfile?
    @PresentationState private var status: MacReplacementStatus?
    @PresentationState private var resuming: Set<String> = []
    @PresentationState private var loadGeneration = 0
    @PresentationState private var detent: PresentationDetent = .large

    init(profile: GatewayProfile?, status: MacReplacementStatus? = nil) {
        self.profile = profile
        _status = PresentationState(wrappedValue: status)
    }

    private var connected: Bool {
        guard let profile else { return status != nil }
        return model.connectionState == .connected && model.profiles.selected?.id == profile.id
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    if let operation = status?.operation {
                        summaryGroup(operation)
                        stepsGroup(operation)
                        if let error = operation.error { errorGroup(error, rollback: operation.rollback) }
                        if let workers = status?.workers, !workers.isEmpty {
                            workersGroup(workers, operation: operation)
                        }
                        terminalGroup(operation)
                    } else if connected {
                        TronSheetLoadingState(label: "Loading replacement…", accent: .tronEmerald)
                    } else {
                        offlineRow(operation: nil)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Replace Mac App", accent: .tronEmerald)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .task(id: PresentationActivityTaskID(
            source: "\(profile?.id ?? "fixed"):\(connected):\(model.foregroundReconciliationGeneration):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            // Poll while visible. While the Gateway is down for the swap the
            // last journal stays on screen; reconnecting restarts this task.
            while !Task.isCancelled, presentationActivity.allowsPresentationPublication, scenePhase == .active {
                await load()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onDisappear { loadGeneration &+= 1 }
    }

    private func load() async {
        guard let profile, connected else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let loaded = await model.loadMacReplacementStatus(for: profile),
              generation == loadGeneration, presentationActivity.allowsPresentationPublication else { return }
        status = loaded
    }

    private func summaryGroup(_ operation: MacReplacementOperation) -> some View {
        let accent = MacReplacementPresentation.stateAccent(operation)
        return TronSettingsGroup("Replacement", accent: accent) {
            VStack(spacing: 0) {
                TronValueRow(
                    icon: operation.path == "quick" ? "hammer" : "shippingbox",
                    title: MacReplacementPresentation.pathTitle(operation.path),
                    detail: MacReplacementPresentation.reasonDetail(operation.reason),
                    accent: .tronEmerald
                )
                TronSettingsDivider(accent: accent)
                TronValueRow(
                    icon: operation.isTerminal ? (operation.state == "succeeded" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill") : "arrow.triangle.2.circlepath",
                    title: MacReplacementPresentation.stateTitle(operation),
                    detail: operation.attempt > 1 ? "Attempt \(operation.attempt)" : nil,
                    accent: accent
                ) {
                    if !operation.isTerminal { TronPulseLoadingIndicator(accent: accent, size: 18) }
                }
                if !connected {
                    TronSettingsDivider(accent: .tronAmber)
                    offlineRow(operation: operation)
                }
            }
        }
    }

    private func offlineRow(operation: MacReplacementOperation?) -> some View {
        TronValueRow(
            icon: "bolt.horizontal.circle",
            title: operation?.swapsGateway == true ? "Gateway down for the app swap" : "Gateway offline",
            detail: "Reconnecting automatically; the full journal appears when it is back.",
            accent: .tronAmber
        ) {
            TronPulseLoadingIndicator(accent: .tronAmber, size: 18)
        }
    }

    private func stepsGroup(_ operation: MacReplacementOperation) -> some View {
        TronSettingsGroup("Steps", accent: .tronEmerald) {
            VStack(spacing: 0) {
                ForEach(Array(operation.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { TronSettingsDivider(accent: .tronEmerald) }
                    TronValueRow(
                        icon: MacReplacementPresentation.stepIcon(step),
                        title: step.title,
                        detail: MacReplacementPresentation.stepDetail(step),
                        accent: MacReplacementPresentation.stepAccent(step)
                    ) {
                        if step.state == "running" {
                            TronPulseLoadingIndicator(accent: .tronAmber, size: 16)
                        }
                    }
                }
            }
        }
    }

    private func errorGroup(_ error: MacReplacementError, rollback: MacReplacementRollback?) -> some View {
        TronSettingsGroup("Error", accent: .tronError) {
            VStack(spacing: 0) {
                TronValueRow(icon: "exclamationmark.triangle", title: "Failed at \(stepTitle(error.step))", detail: error.message, accent: .tronError)
                    .textSelection(.enabled)
                TronSettingsDivider(accent: .tronError)
                TronValueRow(icon: "doc.text", title: "Log", detail: error.log, accent: .tronError)
                    .textSelection(.enabled)
                if let rollback {
                    TronSettingsDivider(accent: .tronAmber)
                    TronValueRow(
                        icon: "arrow.uturn.backward.circle",
                        title: rollback.state == "restored" ? "Previous app restored" : "Rollback \(rollback.state)",
                        detail: rollback.detail,
                        accent: rollback.state == "failed" ? .tronError : .tronAmber
                    )
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func stepTitle(_ name: String) -> String {
        status?.operation?.steps.first { $0.name == name }?.title ?? name
    }

    private func workersGroup(_ workers: [MacReplacementWorker], operation: MacReplacementOperation) -> some View {
        TronSettingsGroup("Stopped Workers", detail: "Each resumes in place, in its own session.", accent: .tronPurple) {
            VStack(spacing: 0) {
                ForEach(Array(workers.enumerated()), id: \.element.id) { index, worker in
                    if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                    TronValueRow(
                        icon: worker.state == "resumed" ? "play.circle.fill" : "pause.circle",
                        title: worker.title,
                        detail: MacReplacementPresentation.workerDetail(worker),
                        accent: .tronPurple
                    ) {
                        if worker.state == "resumable" && operation.isTerminal {
                            Button {
                                Task { await resume(worker, operation: operation) }
                            } label: {
                                TronInlineActionLabel("Resume", isWorking: resuming.contains(worker.taskId), accent: .tronPurple)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(!connected || resuming.contains(worker.taskId))
                            .accessibilityLabel("Resume \(worker.title)")
                        }
                    }
                }
            }
        }
    }

    private func terminalGroup(_ operation: MacReplacementOperation) -> some View {
        TronSettingsGroup("On the Mac", accent: .tronCyan) {
            TronValueRow(
                icon: "terminal",
                title: "scripts/tron mac replace --status --follow",
                detail: operation.logPath,
                accent: .tronCyan
            )
            .textSelection(.enabled)
        }
    }

    private func resume(_ worker: MacReplacementWorker, operation: MacReplacementOperation) async {
        guard let profile else { return }
        resuming.insert(worker.taskId)
        defer { resuming.remove(worker.taskId) }
        if await model.resumeMacReplacementWorker(for: profile, operationID: operation.id, taskID: worker.taskId) {
            await load()
        }
    }
}
