import SwiftUI

@MainActor
@Observable
final class TerminalController {
    var terminal: TerminalSummary?
    var error: String?
    var connectionPhase: TerminalConnectionPhase = .connecting
    var history: [TerminalSummary] = []
    private var presentation: TerminalPresentationTarget?
    private var intent: TerminalPresentationIntent?

    func isRunning(model: AppModel) -> Bool {
        guard let terminal else { return false }
        return terminal.exitedAt == nil && !model.terminalHasExited(terminal.id)
    }

    func start(sessionID: String, model: AppModel) async {
        guard presentation == nil else { return }
        let target = model.beginTerminalPresentation(sessionID: sessionID)
        presentation = target
        guard let intent = beginIntent(model: model) else { return }
        connectionPhase = .connecting
        error = nil
        do {
            let terminals = try await model.listTerminals(intent: intent)
                .sorted { $0.createdAt > $1.createdAt }
            guard owns(intent, model: model) else { return }
            history = terminals
            let selected: TerminalSummary
            if let existing = terminals.first(where: { $0.exitedAt == nil }) {
                selected = try await model.attachTerminal(existing.id, after: 0, intent: intent)
            } else {
                selected = try await model.openTerminal(intent: intent, columns: 80, rows: 24)
            }
            guard owns(intent, model: model) else { return }
            terminal = selected
            history.removeAll { $0.id == selected.id }
            connectionPhase = .connected
        } catch {
            guard owns(intent, model: model) else { return }
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func show(_ selected: TerminalSummary, model: AppModel) async {
        guard let intent = beginIntent(model: model) else { return }
        error = nil
        connectionPhase = .connecting
        terminal = nil
        do {
            let attached = try await model.attachTerminal(selected.id, after: 0, intent: intent)
            guard owns(intent, model: model) else { return }
            terminal = attached
            connectionPhase = .connected
        } catch {
            guard owns(intent, model: model) else { return }
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func openLive(model: AppModel) async {
        guard let intent = beginIntent(model: model) else { return }
        error = nil
        connectionPhase = .connecting
        terminal = nil
        do {
            let opened = try await model.openTerminal(intent: intent, columns: 80, rows: 24)
            guard owns(intent, model: model) else { return }
            terminal = opened
            history = try await model.listTerminals(intent: intent)
            guard owns(intent, model: model) else { return }
            history.removeAll { $0.id == opened.id }
            connectionPhase = .connected
        } catch {
            guard owns(intent, model: model) else { return }
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func stop(model: AppModel) {
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
        Task {
            do { try await model.writeTerminal(id, data: data, intent: intent) }
            catch {
                guard owns(intent, model: model) else { return }
                self.error = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func resize(columns: Int, rows: Int, model: AppModel) {
        guard let id = terminal?.id,
              terminal?.exitedAt == nil,
              let intent,
              model.ownsTerminalIntent(intent) else { return }
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
                self.error = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func terminate(model: AppModel) {
        guard let id = terminal?.id,
              let intent,
              model.ownsTerminalIntent(intent) else { return }
        Task {
            do { try await model.terminateTerminal(id, intent: intent) }
            catch {
                guard owns(intent, model: model) else { return }
                self.error = error.localizedDescription
            }
        }
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

