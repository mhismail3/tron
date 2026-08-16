import SwiftUI

@MainActor
@Observable
final class TerminalController {
    var terminal: TerminalSummary?
    var error: String?
    var actionError: String?
    var connectionPhase: TerminalConnectionPhase = .connecting
    var history: [TerminalSummary] = []
    private enum LifecycleOperation {
        case start
        case show(TerminalSummary)
        case openLive

        var initialPhase: LifecyclePhase {
            switch self {
            case .start: .read
            case .show, .openLive: .connection
            }
        }
    }

    private enum LifecyclePhase: Equatable {
        case read
        case connection
    }

    private struct LifecycleRequest {
        let operation: LifecycleOperation
        let intent: TerminalPresentationIntent
    }

    private struct LifecycleFlight {
        let token: UInt64
        var phase: LifecyclePhase
        let task: Task<Void, Never>
    }

    private var presentation: TerminalPresentationTarget?
    private var intent: TerminalPresentationIntent?
    private var lifecycleGeneration: UInt64 = 0
    private var lifecycleFlight: LifecycleFlight?
    private var pendingLifecycleRequest: LifecycleRequest?

    func isRunning(model: AppModel) -> Bool {
        guard let terminal else { return false }
        return terminal.exitedAt == nil && !model.terminalHasExited(terminal.id)
    }

    func start(sessionID: String, model: AppModel) {
        guard presentation == nil else { return }
        let target = model.beginTerminalPresentation(sessionID: sessionID)
        presentation = target
        guard let intent = beginIntent(model: model) else { return }
        connectionPhase = .connecting
        error = nil
        actionError = nil
        scheduleLifecycle(.start, intent: intent, model: model)
    }

    func show(_ selected: TerminalSummary, model: AppModel) {
        guard let intent = beginIntent(model: model) else { return }
        error = nil
        actionError = nil
        connectionPhase = .connecting
        terminal = nil
        scheduleLifecycle(.show(selected), intent: intent, model: model)
    }

    func openLive(model: AppModel) {
        guard let intent = beginIntent(model: model) else { return }
        error = nil
        actionError = nil
        connectionPhase = .connecting
        terminal = nil
        scheduleLifecycle(.openLive, intent: intent, model: model)
    }

    func stop(model: AppModel) {
        pendingLifecycleRequest = nil
        if lifecycleFlight?.phase == .read { lifecycleFlight?.task.cancel() }
        intent = nil
        terminal = nil
        guard let presentation else { return }
        self.presentation = nil
        model.closeTerminalPresentation(presentation)
    }

    func send(_ bytes: ArraySlice<UInt8>, model: AppModel) {
        guard let id = terminal?.id,
              terminal?.exitedAt == nil,
              let intent,
              model.ownsTerminalIntent(intent) else { return }
        let data = String(decoding: bytes, as: UTF8.self)
        actionError = nil
        Task {
            do { try await model.writeTerminal(id, data: data, intent: intent) }
            catch {
                guard owns(intent, model: model) else { return }
                self.actionError = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func resize(columns: Int, rows: Int, model: AppModel) {
        guard let id = terminal?.id,
              terminal?.exitedAt == nil,
              let intent,
              model.ownsTerminalIntent(intent) else { return }
        actionError = nil
        Task {
            do {
                try await model.resizeTerminal(
                    id,
                    columns: columns,
                    rows: rows,
                    intent: intent
                )
            } catch is CancellationError {
                return
            } catch {
                guard owns(intent, model: model) else { return }
                self.actionError = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func terminate(model: AppModel) {
        guard let id = terminal?.id,
              let intent,
              model.ownsTerminalIntent(intent) else { return }
        actionError = nil
        Task {
            do { try await model.terminateTerminal(id, intent: intent) }
            catch {
                guard owns(intent, model: model) else { return }
                self.actionError = error.localizedDescription
            }
        }
    }

    func clearActionError() {
        actionError = nil
    }

    private func scheduleLifecycle(
        _ operation: LifecycleOperation,
        intent: TerminalPresentationIntent,
        model: AppModel
    ) {
        let request = LifecycleRequest(operation: operation, intent: intent)
        if let flight = lifecycleFlight {
            if flight.phase == .connection {
                pendingLifecycleRequest = request
                return
            }
            flight.task.cancel()
            lifecycleFlight = nil
        }
        pendingLifecycleRequest = nil
        launchLifecycle(request, model: model)
    }

    private func launchLifecycle(_ request: LifecycleRequest, model: AppModel) {
        lifecycleGeneration &+= 1
        let token = lifecycleGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performLifecycle(request, token: token, model: model)
            completeLifecycle(token: token, model: model)
        }
        lifecycleFlight = LifecycleFlight(
            token: token,
            phase: request.operation.initialPhase,
            task: task
        )
    }

    private func performLifecycle(
        _ request: LifecycleRequest,
        token: UInt64,
        model: AppModel
    ) async {
        do {
            switch request.operation {
            case .start:
                let terminals = try await model.listTerminals(intent: request.intent)
                    .sorted { $0.createdAt > $1.createdAt }
                guard owns(request.intent, model: model) else { return }
                history = terminals
                let selected: TerminalSummary
                markLifecycleConnection(token: token)
                if let existing = terminals.first(where: { $0.exitedAt == nil }) {
                    selected = try await model.attachTerminal(existing.id, after: 0, intent: request.intent)
                } else {
                    selected = try await model.openTerminal(intent: request.intent, columns: 80, rows: 24)
                }
                guard owns(request.intent, model: model) else { return }
                terminal = selected
                history.removeAll { $0.id == selected.id }
            case .show(let selected):
                let attached = try await model.attachTerminal(selected.id, after: 0, intent: request.intent)
                guard owns(request.intent, model: model) else { return }
                terminal = attached
            case .openLive:
                let opened = try await model.openTerminal(intent: request.intent, columns: 80, rows: 24)
                guard owns(request.intent, model: model) else { return }
                terminal = opened
                markLifecycleRead(token: token)
                history = try await model.listTerminals(intent: request.intent)
                guard owns(request.intent, model: model) else { return }
                history.removeAll { $0.id == opened.id }
            }
            connectionPhase = .connected
        } catch {
            guard owns(request.intent, model: model) else { return }
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    private func markLifecycleConnection(token: UInt64) {
        guard var flight = lifecycleFlight, flight.token == token else { return }
        flight.phase = .connection
        lifecycleFlight = flight
    }

    private func markLifecycleRead(token: UInt64) {
        guard var flight = lifecycleFlight, flight.token == token else { return }
        flight.phase = .read
        lifecycleFlight = flight
    }

    private func completeLifecycle(token: UInt64, model: AppModel) {
        guard lifecycleFlight?.token == token else { return }
        lifecycleFlight = nil
        guard let pending = pendingLifecycleRequest else { return }
        pendingLifecycleRequest = nil
        guard owns(pending.intent, model: model) else { return }
        launchLifecycle(pending, model: model)
    }

    private func beginIntent(model: AppModel) -> TerminalPresentationIntent? {
        guard let presentation,
              let next = model.beginTerminalIntent(for: presentation) else { return nil }
        intent = next
        return next
    }

    private func owns(_ candidate: TerminalPresentationIntent, model: AppModel) -> Bool {
        intent == candidate && model.ownsTerminalIntent(candidate)
    }
}

enum TerminalConnectionPhase: Equatable {
    case connecting, connected, reconnecting, unavailable

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .connected: .tronEmerald
        case .connecting, .reconnecting: .tronAmber
        case .unavailable: .tronError
        }
    }
}

