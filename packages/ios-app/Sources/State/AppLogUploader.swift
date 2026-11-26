import Foundation
import TronMobileCore

@MainActor
final class AppLogUploader {
    struct Connection: Sendable {
        let client: GatewayClient
        let id: Int
    }

    private struct AppendRequest: Encodable, Sendable {
        let commandId: String
        let bootId: String
        let firstSequence: Int
        let lines: [String]
        let gapFrom: Int?
        let reason: String?
    }

    static let capability = "device-logs.v1"

    private let log: AppLog
    private let interval: Duration
    private let connection: @MainActor () -> Connection?
    private var owner: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var wakes: AsyncStream<Void>.Continuation?

    init(log: AppLog, interval: Duration = .seconds(60), connection: @escaping @MainActor () -> Connection?) {
        self.log = log
        self.interval = interval
        self.connection = connection
    }

    func start() {
        guard owner == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        let interval = interval
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                continuation.yield(())
            }
        }
        owner = Task { [weak self] in
            await self?.pass()
            for await _ in stream {
                await self?.pass()
            }
        }
    }

    func nudge() {
        wakes?.yield(())
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        owner?.cancel()
        owner = nil
        wakes?.finish()
        wakes = nil
    }

    private func pass() async {
        guard let current = connection() else { return }
        do {
            var held = try await request(current, "client.logs.cursor", EmptyParams())
            while !Task.isCancelled, let batch = await log.uploadBatch(after: held) {
                let acknowledged = try await request(current, "client.logs.append", AppendRequest(
                    commandId: UUID().uuidString, bootId: batch.bootId, firstSequence: batch.firstSequence,
                    lines: batch.lines, gapFrom: batch.gapFrom, reason: batch.gapFrom == nil ? nil : "local-rotation"
                ))
                guard acknowledged != held else { return }
                held = acknowledged
            }
        } catch {
            await log.recordCausal(name: "logs.upload", outcome: "failure", level: "warning",
                                   details: "code=\(GatewayDiagnosticFailure.code(error))")
        }
    }

    private func request<P: Encodable & Sendable>(_ current: Connection, _ method: String, _ params: P) async throws -> AppLogHeldCursor {
        let value = try await current.client.requestValue(method, params, expectedEpochID: current.id)
        return try JSONDecoder().decode(AppLogHeldCursor.self, from: JSONEncoder().encode(value))
    }
}
