import Foundation
import os

enum PerformanceOperation: CaseIterable, Sendable {
    case gatewayConnect
    case sessionOpen
    case sessionSync
    case sessionResync
    case receiptResolution
    case cacheLoad
    case cacheSave
    case chatProjection
    case firstReadyFrame
    case scrollCommandSettle
    case prependSettle
    case terminalAttachReplay
}

enum PerformanceResult: Int, Sendable {
    case success = 0
    case failure = 1
    case cancelled = 2
    case discarded = 3

    static func forFailure(_ error: Error) -> PerformanceResult {
        Task.isCancelled || error is CancellationError ? .cancelled : .failure
    }
}

struct PerformanceMetrics: Equatable, Sendable {
    let itemCount: Int
    let byteCount: Int

    init(itemCount: Int = 0, byteCount: Int = 0) {
        self.itemCount = max(0, itemCount)
        self.byteCount = max(0, byteCount)
    }

    static let none = PerformanceMetrics()
}

struct PerformanceInterval: Sendable {
    let operation: PerformanceOperation
    fileprivate let state: OSSignpostIntervalState?

    init(operation: PerformanceOperation, state: OSSignpostIntervalState? = nil) {
        self.operation = operation
        self.state = state
    }
}

protocol PerformanceSignposting: Sendable {
    func begin(_ operation: PerformanceOperation) -> PerformanceInterval
    func end(
        _ interval: PerformanceInterval,
        result: PerformanceResult,
        metrics: PerformanceMetrics
    )
}

struct SystemPerformanceSignposts: PerformanceSignposting {
    static let shared = SystemPerformanceSignposts()

    private let gateway = OSSignposter(subsystem: "com.tron.mobile", category: "Gateway")
    private let sessions = OSSignposter(subsystem: "com.tron.mobile", category: "Sessions")
    private let cache = OSSignposter(subsystem: "com.tron.mobile", category: "Cache")
    private let chat = OSSignposter(subsystem: "com.tron.mobile", category: "Chat")
    private let terminal = OSSignposter(subsystem: "com.tron.mobile", category: "Terminal")

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let signposter = signposter(for: operation)
        guard signposter.isEnabled else { return PerformanceInterval(operation: operation) }
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        switch operation {
        case .gatewayConnect:
            state = signposter.beginInterval("Gateway Connect", id: id)
        case .sessionOpen:
            state = signposter.beginInterval("Session Open", id: id)
        case .sessionSync:
            state = signposter.beginInterval("Session Sync", id: id)
        case .sessionResync:
            state = signposter.beginInterval("Session Resync", id: id)
        case .receiptResolution:
            state = signposter.beginInterval("Receipt Resolution", id: id)
        case .cacheLoad:
            state = signposter.beginInterval("Cache Load", id: id)
        case .cacheSave:
            state = signposter.beginInterval("Cache Save", id: id)
        case .chatProjection:
            state = signposter.beginInterval("Chat Projection", id: id)
        case .firstReadyFrame:
            state = signposter.beginInterval("First Ready Frame", id: id)
        case .scrollCommandSettle:
            state = signposter.beginAnimationInterval("Scroll Command Settle", id: id)
        case .prependSettle:
            state = signposter.beginAnimationInterval("Prepend Settle", id: id)
        case .terminalAttachReplay:
            state = signposter.beginInterval("Terminal Attach Replay", id: id)
        }
        return PerformanceInterval(operation: operation, state: state)
    }

    func end(
        _ interval: PerformanceInterval,
        result: PerformanceResult,
        metrics: PerformanceMetrics = .none
    ) {
        guard let state = interval.state else { return }
        let signposter = signposter(for: interval.operation)
        switch interval.operation {
        case .gatewayConnect:
            signposter.endInterval("Gateway Connect", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .sessionOpen:
            signposter.endInterval("Session Open", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .sessionSync:
            signposter.endInterval("Session Sync", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .sessionResync:
            signposter.endInterval("Session Resync", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .receiptResolution:
            signposter.endInterval("Receipt Resolution", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .cacheLoad:
            signposter.endInterval("Cache Load", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .cacheSave:
            signposter.endInterval("Cache Save", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .chatProjection:
            signposter.endInterval("Chat Projection", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .firstReadyFrame:
            signposter.endInterval("First Ready Frame", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .scrollCommandSettle:
            signposter.endInterval("Scroll Command Settle", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .prependSettle:
            signposter.endInterval("Prepend Settle", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        case .terminalAttachReplay:
            signposter.endInterval("Terminal Attach Replay", state, "result=\(result.rawValue, privacy: .public) items=\(metrics.itemCount, privacy: .public) bytes=\(metrics.byteCount, privacy: .public)")
        }
    }

    private func signposter(for operation: PerformanceOperation) -> OSSignposter {
        switch operation {
        case .gatewayConnect:
            gateway
        case .sessionOpen, .sessionSync, .sessionResync, .receiptResolution:
            sessions
        case .cacheLoad, .cacheSave:
            cache
        case .chatProjection, .firstReadyFrame, .scrollCommandSettle, .prependSettle:
            chat
        case .terminalAttachReplay:
            terminal
        }
    }
}
