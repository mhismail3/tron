import Foundation

struct GatewayConnectionFailureClassifier: Sendable {
    private(set) var consecutiveNeverOpened = 0
    private(set) var interface: String?
    private(set) var episodeOpenedTransport = false
    private var attemptGeneration = 0

    mutating func beginAttempt() -> Int {
        attemptGeneration &+= 1
        return attemptGeneration
    }

    var noPath: GatewayNoPathPresentation? {
        guard consecutiveNeverOpened >= 2, !episodeOpenedTransport else { return nil }
        return GatewayNoPathPresentation(interface: interface)
    }

    @discardableResult
    mutating func failedAttempt(
        _ diagnostic: GatewayConnectionDiagnostic?,
        code: String,
        attemptGeneration: Int? = nil
    ) -> Bool {
        guard attemptGeneration == nil || attemptGeneration == self.attemptGeneration,
              code != "cancelled" else { return false }
        guard code != "ping_timeout",
              let diagnostic,
              diagnostic.outcome == .failure,
              diagnostic.stage == .transportOpen,
              diagnostic.handshake?.transportOpened == false else {
            episodeOpenedTransport = true
            consecutiveNeverOpened = 0
            return true
        }
        guard !episodeOpenedTransport else { return false }
        consecutiveNeverOpened += 1
        interface = GatewayNoPathPresentation.interfaceLabel(from: diagnostic.handshake?.networkInterfaces) ?? interface
        return true
    }

    mutating func reset() {
        attemptGeneration &+= 1
        consecutiveNeverOpened = 0
        interface = nil
        episodeOpenedTransport = false
    }
}
