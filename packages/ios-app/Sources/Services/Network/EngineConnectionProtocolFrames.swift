import Foundation

// MARK: - Engine Protocol Frames

struct EngineHelloFrame: Encodable {
    let type = "hello"
    let id: String
    let protocolVersion: UInt64
    let clientName: String?
    let clientVersion: String?
    let sessionId: String?
    let workspaceId: String?
}

struct EngineHelloResult: Decodable, Equatable, Sendable {
    let type: String
    let id: String?
    let protocolVersion: UInt64
    let minimumSupportedVersion: UInt64
    let serverId: String
    let currentCatalogRevision: UInt64
}

struct EngineFunctionCallFrame<P: Encodable>: Encodable {
    let type = "invoke"
    let id: String
    let functionId: String
    let payload: P
    let expectedRevision: UInt64?
    let idempotencyKey: String?
    let context: EngineInvocationContext?
}

struct EngineSubscribeFrame: Encodable {
    let type = "subscribe"
    let id: String
    let topic: String
    let cursor: UInt64?
    let filters: [String: AnyCodable]?
    let limit: Int?
    let context: EngineInvocationContext?
}

struct EnginePollFrame: Encodable {
    let type = "poll"
    let id: String
    let subscriptionId: String?
    let topic: String?
    let cursor: UInt64?
    let filters: [String: AnyCodable]?
    let limit: Int?
    let context: EngineInvocationContext?
}

struct EngineAckFrame: Encodable {
    let type = "ack"
    let id: String
    let subscriptionId: String
    let cursor: UInt64
}

struct EngineResponseEnvelope<R: Decodable>: Decodable {
    let type: String
    let id: String?
    let ok: Bool
    let result: R?
    let error: EngineProtocolError?
    let traceId: String?
    let catalogRevision: UInt64?
}

// MARK: - URLSession Delegate

/// `URLSession` + `URLSessionWebSocket` delegate that detects HTTP 401 on
/// the WS upgrade and routes the failure to `EngineConnection.markUnauthorized`.
///
/// URLSession retains its delegate; `EngineConnection` holds a strong
/// reference here so the delegate's lifetime tracks the session — and
/// `urlSession(_:didBecomeInvalidWithError:)` clears that reference when the
/// session is torn down (manual disconnect, retry, unauthorized).
final class EngineConnectionSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Stored as `weak` to avoid the URLSession ↔ delegate ↔ service retain
    /// cycle. `@unchecked Sendable` because Swift can't reason about the
    /// `weak` storage being safely accessed across actor boundaries — we
    /// hop to MainActor inside every callback before touching `owner`.
    private weak var ownerRef: EngineConnection?

    init(owner: EngineConnection) {
        self.ownerRef = owner
    }

    /// Snapshot the weak ref; the only caller is the `MainActor.run` body
    /// inside the URLSession callbacks below.
    @MainActor
    private func owner() -> EngineConnection? { ownerRef }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            owner()?.markWebSocketOpened(webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            await owner()?.markWebSocketClosed(webSocketTask, closeCode: closeCode)
        }
    }

    /// URLSession exposes failed WebSocket upgrade responses most reliably
    /// through task metrics. A 401 means the bearer token is
    /// wrong/missing/rotated — route to `markUnauthorized` so the state
    /// machine parks for re-pair.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        Task { @MainActor in
            owner()?.logWebSocketTaskMetrics(metrics)
        }
        for transaction in metrics.transactionMetrics {
            if let response = transaction.response {
                Task { @MainActor in
                    owner()?.logWebSocketUpgradeResponse(response)
                }
                record(response: response)
            }
        }
    }

    /// Some failed upgrades only expose their response at completion, so
    /// keep this as a second chance after metrics collection.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response {
            Task { @MainActor in
                owner()?.logWebSocketUpgradeResponse(response)
            }
            record(response: response)
        }
        guard let error else { return }
        Task { @MainActor in
            owner()?.logWebSocketTaskCompletionError(error)
            owner()?.markWebSocketOpenFailed(task, error: error)
        }
    }

    private func record(response: URLResponse) {
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 401 else {
            return
        }
        Task { @MainActor in
            owner()?.markUnauthorized(reason: "Server rejected authentication")
        }
    }
}
