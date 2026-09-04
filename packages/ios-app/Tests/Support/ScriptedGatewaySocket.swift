import Foundation
import Synchronization
@testable import TronMobile

actor ScriptedGatewaySocket: GatewaySocketConnection {
    private struct Receiver {
        let token: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private struct Waiter {
        let token: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var inbound: [Data] = []
    private var inboundFailures: [Error] = []
    private var receivers: [Receiver] = []
    private var nextReceiverToken = 0
    private var sent: [Data] = []
    private var sentWaiters: [Waiter] = []
    private var sendInvocations = 0
    private var sendFailures: [Error] = []
    private var sendInvocationWaiters: [Waiter] = []
    private var pingInvocations = 0
    private var pingFailures: [Error] = []
    private var pingWaiters: [Waiter] = []
    private var pingBarrierWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var sendBarrierWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var closeInvocations = 0
    private var closeTransitions = 0
    private var closeInvocationWaiters: [Waiter] = []
    private var closeWaiters: [Waiter] = []
    private var nextWaiterToken = 0
    private enum WaiterKind { case sent, sendInvocation, pingInvocation, closeInvocation, closeTransition }

    private var isClosed = false
    private var suspendsSend: Bool
    private var suspendsPing: Bool
    private var suspendsClose: Bool
    private let deliversCallbacksAfterClose: Bool
    private let deliversSendsAfterCancellation: Bool
    private var closeBarrierWaiters: [Int: CheckedContinuation<Void, Error>] = [:]

    init(
        suspendsSend: Bool = false,
        suspendsPing: Bool = false,
        suspendsClose: Bool = false,
        deliversCallbacksAfterClose: Bool = false,
        deliversSendsAfterCancellation: Bool = false
    ) {
        self.suspendsSend = suspendsSend
        self.suspendsPing = suspendsPing
        self.suspendsClose = suspendsClose
        self.deliversCallbacksAfterClose = deliversCallbacksAfterClose
        self.deliversSendsAfterCancellation = deliversSendsAfterCancellation
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw CancellationError() }
        sendInvocations += 1
        resumeSatisfiedWaiters(&sendInvocationWaiters, observedCount: sendInvocations)
        if !sendFailures.isEmpty { throw sendFailures.removeFirst() }
        if suspendsSend {
            let ignoresCancellation = deliversSendsAfterCancellation
            let barrierToken = nextWaiterToken
            nextWaiterToken += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || !suspendsSend {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        sendBarrierWaiters[barrierToken] = continuation
                    }
                }
            } onCancel: {
                guard !ignoresCancellation else { return }
                Task { await self.cancelSendBarrierWaiter(token: barrierToken) }
            }
        }
        if !deliversSendsAfterCancellation { try Task.checkCancellation() }
        guard !isClosed else { throw CancellationError() }
        sent.append(data)
        resumeSatisfiedWaiters(&sentWaiters, observedCount: sent.count)
    }

    func ping() async throws {
        guard !isClosed else { throw CancellationError() }
        pingInvocations += 1
        resumeSatisfiedWaiters(&pingWaiters, observedCount: pingInvocations)
        if !pingFailures.isEmpty { throw pingFailures.removeFirst() }
        if suspendsPing {
            let token = nextWaiterToken
            nextWaiterToken += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || !suspendsPing {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pingBarrierWaiters[token] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelPingBarrierWaiter(token: token) }
            }
        }
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
    }

    func receive() async throws -> Data {
        guard !isClosed else { throw CancellationError() }
        if !inboundFailures.isEmpty { throw inboundFailures.removeFirst() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        let token = nextReceiverToken
        nextReceiverToken += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receivers.append(.init(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelReceiver(token: token) }
        }
    }

    func close() async {
        closeInvocations += 1
        resumeSatisfiedWaiters(&closeInvocationWaiters, observedCount: closeInvocations)
        if suspendsClose {
            let barrierToken = nextWaiterToken
            nextWaiterToken += 1
            // GatewayClient cancels its receive task before that same task closes an
            // overflowing socket. Preserve the scripted barrier for that pre-existing
            // cancellation, while still making newly cancelled close waits exit.
            let cancellationWasAlreadySet = Task.isCancelled
            try? await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if (!cancellationWasAlreadySet && Task.isCancelled) || !suspendsClose {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        closeBarrierWaiters[barrierToken] = continuation
                    }
                }
            } onCancel: {
                guard !cancellationWasAlreadySet else { return }
                Task { await self.cancelCloseBarrierWaiter(token: barrierToken) }
            }
        }
        guard !isClosed else { return }
        isClosed = true
        closeTransitions += 1
        let pendingPings = pingBarrierWaiters
        pingBarrierWaiters.removeAll()
        for continuation in pendingPings.values { continuation.resume(throwing: CancellationError()) }
        if !deliversCallbacksAfterClose {
            let pendingReceivers = receivers
            receivers.removeAll()
            for receiver in pendingReceivers { receiver.continuation.resume(throwing: CancellationError()) }
        }
        resumeSatisfiedWaiters(&closeWaiters, observedCount: closeTransitions)
    }

    func failNextSend(_ error: Error) {
        sendFailures.append(error)
    }

    func failNextPing(_ error: Error) {
        pingFailures.append(error)
    }

    func suspendSends() {
        suspendsSend = true
    }

    func releasePing() {
        suspendsPing = false
        let waiters = pingBarrierWaiters.values
        pingBarrierWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func releaseSend() {
        suspendsSend = false
        let waiters = sendBarrierWaiters.values
        sendBarrierWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func releaseClose() {
        suspendsClose = false
        let waiters = closeBarrierWaiters.values
        closeBarrierWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func enqueue(_ data: Data) {
        guard !isClosed || deliversCallbacksAfterClose else { return }
        if receivers.isEmpty {
            inbound.append(data)
        } else {
            receivers.removeFirst().continuation.resume(returning: data)
        }
    }

    func failPendingReceivers(_ error: Error) {
        guard !receivers.isEmpty else {
            inboundFailures.append(error)
            return
        }
        let pendingReceivers = receivers
        receivers.removeAll()
        for receiver in pendingReceivers { receiver.continuation.resume(throwing: error) }
    }

    func sentFrames() -> [Data] { sent }
    func sendInvocationCount() -> Int { sendInvocations }
    func pingInvocationCount() -> Int { pingInvocations }
    func pendingReceiverCount() -> Int { receivers.count }
    func closeInvocationCount() -> Int { closeInvocations }
    func closeTransitionCount() -> Int { closeTransitions }
    func closed() -> Bool { isClosed }

    func waitUntilSent(count: Int) async throws {
        try await wait(until: count, observedCount: sent.count, kind: .sent)
    }

    func waitUntilSendInvoked(count: Int) async throws {
        try await wait(until: count, observedCount: sendInvocations, kind: .sendInvocation)
    }

    func waitUntilPingInvoked(count: Int) async throws {
        try await wait(until: count, observedCount: pingInvocations, kind: .pingInvocation)
    }

    func waitUntilCloseInvoked(count: Int = 1) async throws {
        try await wait(until: count, observedCount: closeInvocations, kind: .closeInvocation)
    }

    func waitUntilClosed(count: Int = 1) async throws {
        try await wait(until: count, observedCount: closeTransitions, kind: .closeTransition)
    }

    private func wait(until count: Int, observedCount: Int, kind: WaiterKind) async throws {
        if observedCount >= count { return }
        let token = nextWaiterToken
        nextWaiterToken += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let waiter = Waiter(token: token, count: count, continuation: continuation)
                    switch kind {
                    case .sent: sentWaiters.append(waiter)
                    case .sendInvocation: sendInvocationWaiters.append(waiter)
                    case .pingInvocation: pingWaiters.append(waiter)
                    case .closeInvocation: closeInvocationWaiters.append(waiter)
                    case .closeTransition: closeWaiters.append(waiter)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    private func cancelReceiver(token: Int) {
        guard !deliversCallbacksAfterClose else { return }
        guard let index = receivers.firstIndex(where: { $0.token == token }) else { return }
        receivers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(token: Int) {
        if let index = sentWaiters.firstIndex(where: { $0.token == token }) {
            sentWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = sendInvocationWaiters.firstIndex(where: { $0.token == token }) {
            sendInvocationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = pingWaiters.firstIndex(where: { $0.token == token }) {
            pingWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = closeInvocationWaiters.firstIndex(where: { $0.token == token }) {
            closeInvocationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = closeWaiters.firstIndex(where: { $0.token == token }) {
            closeWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelPingBarrierWaiter(token: Int) {
        pingBarrierWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    private func cancelSendBarrierWaiter(token: Int) {
        sendBarrierWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    private func cancelCloseBarrierWaiter(token: Int) {
        closeBarrierWaiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedWaiters(_ waiters: inout [Waiter], observedCount: Int) {
        let ready = waiters.filter { observedCount >= $0.count }
        waiters.removeAll { observedCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

final class ScriptedGatewaySocketFactory: Sendable {
    private struct State {
        var sockets: [ScriptedGatewaySocket]
        var nextSocket = 0
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(socket: ScriptedGatewaySocket) {
        state = Mutex(State(sockets: [socket]))
    }

    init(sockets: [ScriptedGatewaySocket]) {
        precondition(!sockets.isEmpty)
        state = Mutex(State(sockets: sockets))
    }

    var factory: GatewaySocketFactory {
        GatewaySocketFactory { request in
            self.state.withLock { state in
                precondition(state.nextSocket < state.sockets.count, "Scripted socket factory exhausted")
                defer { state.nextSocket += 1 }
                state.requests.append(request)
                return state.sockets[state.nextSocket]
            }
        }
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }
}
