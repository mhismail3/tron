import Foundation
import TronMobileCore

@MainActor
final class AppLogUploader {
    struct Transport: Sendable {
        let ready: @MainActor @Sendable () -> Bool
        let held: @MainActor @Sendable () async throws -> AppLogHeldCursor
        let append: @MainActor @Sendable (AppLogUploadBatch) async throws -> AppLogHeldCursor
    }

    struct Connection: Sendable {
        let id: Int
        let supportsDeviceLogs: Bool
    }

    static func gateway(
        client: GatewayClient,
        connection: @escaping @MainActor @Sendable () -> Connection?
    ) -> Transport {
        Transport(
            ready: { connection()?.supportsDeviceLogs == true },
            held: {
                guard let current = connection() else { throw CancellationError() }
                let value = try await client.requestValue("client.logs.cursor", EmptyParams(), expectedEpochID: current.id)
                return try JSONDecoder().decode(AppLogHeldCursor.self, from: JSONEncoder().encode(value))
            },
            append: { batch in
                guard let current = connection() else { throw CancellationError() }
                let value = try await client.requestValue(
                    "client.logs.append", AppendRequest(batch: batch), expectedEpochID: current.id
                )
                return try JSONDecoder().decode(AppLogHeldCursor.self, from: JSONEncoder().encode(value))
            }
        )
    }

    struct AppendRequest: Encodable {
        let commandId: String
        let bootId: String
        let firstSequence: Int
        let lines: [String]
        let gapFrom: Int?
        let reason: String?

        init(batch: AppLogUploadBatch) {
            commandId = UUID().uuidString
            bootId = batch.bootId
            firstSequence = batch.firstSequence
            lines = batch.lines
            gapFrom = batch.gapFrom
            reason = batch.gapFrom == nil ? nil : AppLogUploadPlanner.gapReason
        }
    }

    static let interval: Duration = .seconds(60)
    static let maximumAttemptsPerPass = 3

    private let log: AppLog
    private let transport: Transport
    private let interval: Duration
    private var owner: Task<Void, Never>?
    private var wakes: AsyncStream<Void>.Continuation?

    init(log: AppLog, transport: Transport, interval: Duration = AppLogUploader.interval) {
        self.log = log
        self.transport = transport
        self.interval = interval
    }

    func start() {
        guard owner == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        owner = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass()
                await self.waitForNextPass(stream)
            }
        }
    }

    func nudge() {
        wakes?.yield(())
    }

    func stop() {
        owner?.cancel()
        owner = nil
        wakes?.finish()
        wakes = nil
    }

    private func waitForNextPass(_ stream: AsyncStream<Void>) async {
        let interval = interval
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: interval) }
            group.addTask { for await _ in stream { break } }
            await group.next()
            group.cancelAll()
        }
    }

    private func pass() async {
        for _ in 0..<Self.maximumAttemptsPerPass {
            guard !Task.isCancelled, transport.ready() else { return }
            do {
                let held = try await transport.held()
                let batches = AppLogUploadPlanner.batches(epochs: await log.uploadEpochs(), held: held)
                var complete = true
                for batch in batches {
                    try Task.checkCancellation()
                    let acknowledged = try await transport.append(batch)
                    let lastSequence = batch.firstSequence + batch.lines.count - 1
                    guard acknowledged.bootId == batch.bootId, acknowledged.sequence == lastSequence else {
                        complete = false
                        break
                    }
                }
                if complete { return }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }
}
