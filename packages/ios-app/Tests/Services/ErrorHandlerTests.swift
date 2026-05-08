import Testing
import Darwin
import Foundation

@testable import TronMobile

@Suite("ErrorHandler routing")
@MainActor
struct ErrorHandlerTests {

    // MARK: - Helpers

    private func makeSUT() -> (ErrorHandler, ToastCenter) {
        let toast = ToastCenter(clock: MockAsyncClock(mode: .instant))
        let handler = ErrorHandler(toastCenter: toast)
        return (handler, toast)
    }

    private func anError(_ description: String = "generic failure") -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    // MARK: - Transient → toast routing

    @Test("handle pushes a toast with message + context")
    func handleRoutesToToast() {
        let (handler, toast) = makeSUT()
        handler.handle(anError("Connection refused"), context: "Server sync")
        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].message == "Server sync: Connection refused")
        #expect(toast.toasts[0].severity == .error)
    }

    @Test("handle does not populate modal queue")
    func handleDoesNotSetModal() {
        let (handler, _) = makeSUT()
        handler.handle(anError(), context: "x")
        #expect(handler.showError == false)
        #expect(handler.currentError == nil)
    }

    @Test("handle maps EngineConnectionError.notConnected to connection.transient dedup key")
    func notConnectedDedupKey() {
        let (handler, toast) = makeSUT()
        handler.handle(EngineConnectionError.notConnected, context: "Session refresh")
        handler.handle(EngineConnectionError.notConnected, context: "Session refresh")
        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].dedupKey == "connection.transient")
    }

    @Test("handle maps EngineConnectionError.timeout to connection.transient")
    func timeoutDedupKey() {
        let (handler, toast) = makeSUT()
        handler.handle(EngineConnectionError.timeout, context: "Session refresh")
        handler.handle(EngineConnectionError.timeout, context: "Session refresh")
        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].dedupKey == "connection.transient")
    }

    @Test("handle maps EngineConnectionError.connectionFailed to connection.transient")
    func connectionFailedDedupKey() {
        let (handler, toast) = makeSUT()
        handler.handle(EngineConnectionError.connectionFailed("boom"), context: "x")
        handler.handle(EngineConnectionError.connectionFailed("other"), context: "y")
        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].dedupKey == "connection.transient")
    }

    @Test("handle maps EngineClientError.connectionNotEstablished to connection.transient")
    func rpcConnectionNotEstablishedDedupKey() {
        let (handler, toast) = makeSUT()
        handler.handle(EngineClientError.connectionNotEstablished, context: "x")
        handler.handle(EngineClientError.connectionNotEstablished, context: "y")
        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].dedupKey == "connection.transient")
    }

    @Test("handle maps native socket aborts to connection.transient")
    func nativeSocketAbortDedupKey() {
        let (handler, toast) = makeSUT()
        let abort = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNABORTED),
            userInfo: [NSLocalizedDescriptionKey: "Software caused connection abort"]
        )
        let lost = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        )

        handler.handle(abort, context: "Session refresh")
        handler.handle(lost, context: "Session refresh")

        #expect(toast.toasts.count == 1)
        #expect(toast.toasts[0].dedupKey == "connection.transient")
    }

    @Test("handle uses no dedup key for non-connection errors")
    func nonConnectionNoDedupKey() {
        let (handler, toast) = makeSUT()
        handler.handle(anError("random"), context: "x")
        handler.handle(anError("other"), context: "x")
        #expect(toast.toasts.count == 2)
        #expect(toast.toasts[0].dedupKey == nil)
    }

    @Test("showError routes to toast with matching severity")
    func showErrorRoutesSeverity() {
        let (handler, toast) = makeSUT()
        handler.showError("warn", severity: .warning)
        handler.showError("info", severity: .info)
        handler.showError("err")  // default .error

        #expect(toast.toasts.count == 3)
        #expect(toast.toasts[0].severity == .warning)
        #expect(toast.toasts[1].severity == .info)
        #expect(toast.toasts[2].severity == .error)
    }

    // MARK: - Fatal → modal routing

    @Test("handleFatal enqueues modal error")
    func handleFatalEnqueues() {
        let (handler, toast) = makeSUT()
        handler.handleFatal(anError("oops"), context: "Session resume")
        #expect(handler.showError)
        #expect(handler.currentError?.message == "Session resume: oops")
        #expect(toast.toasts.isEmpty, "fatal does not also toast")
    }

    @Test("handleFatal dedupes by message")
    func handleFatalDedupes() {
        let (handler, _) = makeSUT()
        handler.handleFatal(anError("same"), context: "x")
        handler.handleFatal(anError("same"), context: "x")
        handler.handleFatal(anError("same"), context: "x")

        var count = 0
        while handler.showError {
            count += 1
            handler.clearError()
        }
        #expect(count == 1)
    }

    @Test("handleFatal respects max queue size (5)")
    func handleFatalMaxQueue() {
        let (handler, _) = makeSUT()
        for i in 0..<10 {
            handler.handleFatal(anError("err \(i)"), context: nil)
        }
        // First enqueued is always displayed; max queue is 5.
        #expect(handler.currentError?.message == "err 0")

        var count = 0
        while handler.showError {
            count += 1
            handler.clearError()
        }
        #expect(count <= 5)
    }

    @Test("clearError advances to next fatal")
    func clearErrorAdvances() {
        let (handler, _) = makeSUT()
        handler.handleFatal(anError("first"), context: nil)
        handler.handleFatal(anError("second"), context: nil)

        #expect(handler.currentError?.message == "first")
        handler.clearError()
        #expect(handler.currentError?.message == "second")
        handler.clearError()
        #expect(handler.showError == false)
    }

    @Test("clearAll empties fatal queue")
    func clearAllEmpties() {
        let (handler, _) = makeSUT()
        handler.handleFatal(anError("1"), context: nil)
        handler.handleFatal(anError("2"), context: nil)
        handler.clearAll()
        #expect(handler.showError == false)
    }

    @Test("clearError on empty queue is safe")
    func clearErrorEmpty() {
        let (handler, _) = makeSUT()
        handler.clearError()
        handler.clearError()
        #expect(handler.showError == false)
    }

    // MARK: - Silent logging

    @Test("log does not surface to user")
    func logSilent() {
        let (handler, toast) = makeSUT()
        handler.log(anError(), context: "ctx")
        #expect(handler.showError == false)
        #expect(toast.toasts.isEmpty)
    }

    @Test("logError does not surface to user")
    func logErrorSilent() {
        let (handler, toast) = makeSUT()
        handler.logError(anError(), context: "ctx")
        handler.logError(anError(), context: "ctx", category: .engine)
        #expect(handler.showError == false)
        #expect(toast.toasts.isEmpty)
    }

    @Test("logWarning does not surface to user")
    func logWarningSilent() {
        let (handler, toast) = makeSUT()
        handler.logWarning("whoops")
        #expect(handler.showError == false)
        #expect(toast.toasts.isEmpty)
    }

    // MARK: - classifyDedupKey static

    @Test("classifyDedupKey handles each EngineConnectionError case")
    func classifyDedupKeyWebSocket() {
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.notConnected) == "connection.transient")
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.timeout) == "connection.transient")
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.connectionFailed("x")) == "connection.transient")
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.invalidResponse) == nil)
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.encodingError) == nil)
        #expect(ErrorHandler.classifyDedupKey(for: EngineConnectionError.decodingError("x")) == nil)
    }

    @Test("classifyDedupKey handles each EngineClientError case")
    func classifyDedupKeyEngineProtocol() {
        #expect(ErrorHandler.classifyDedupKey(for: EngineClientError.connectionNotEstablished) == "connection.transient")
        #expect(ErrorHandler.classifyDedupKey(for: EngineClientError.noActiveSession) == "connection.transient")
        #expect(ErrorHandler.classifyDedupKey(for: EngineClientError.invalidURL) == nil)
    }

    @Test("classifyDedupKey handles native transient transport errors")
    func classifyDedupKeyNativeTransport() {
        let abort = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNABORTED),
            userInfo: nil
        )

        #expect(ErrorHandler.classifyDedupKey(for: abort) == "connection.transient")
    }
}
