import Testing
import Foundation

@testable import TronMobile

@Suite("ErrorHandler Queue Tests")
@MainActor
struct ErrorHandlerTests {

    private func makeSUT() -> ErrorHandler {
        // Use the shared singleton since it's the only way to create one
        let handler = ErrorHandler.shared
        handler.clearAll()
        return handler
    }

    @Test("handle shows first error")
    func handleShowsError() {
        let sut = makeSUT()
        sut.handle(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"]))

        #expect(sut.showError == true)
        #expect(sut.currentError?.message == "Test error")
        #expect(sut.currentError?.severity == .error)
    }

    @Test("clearError advances to next queued error")
    func clearErrorAdvances() {
        let sut = makeSUT()
        sut.showError("First error")
        sut.showError("Second error")

        #expect(sut.currentError?.message == "First error")

        sut.clearError()
        #expect(sut.showError == true)
        #expect(sut.currentError?.message == "Second error")

        sut.clearError()
        #expect(sut.showError == false)
        #expect(sut.currentError == nil)
    }

    @Test("clearAll removes all queued errors")
    func clearAllRemovesAll() {
        let sut = makeSUT()
        sut.showError("Error 1")
        sut.showError("Error 2")
        sut.showError("Error 3")

        sut.clearAll()
        #expect(sut.showError == false)
        #expect(sut.currentError == nil)
    }

    @Test("duplicate messages are deduplicated")
    func deduplicatesSameMessage() {
        let sut = makeSUT()
        sut.showError("Same error")
        sut.showError("Same error")
        sut.showError("Same error")

        #expect(sut.currentError?.message == "Same error")
        sut.clearError()
        // Only one was queued despite three calls
        #expect(sut.showError == false)
    }

    @Test("queue respects max size")
    func maxQueueSize() {
        let sut = makeSUT()
        for i in 0..<10 {
            sut.showError("Error \(i)")
        }

        // Max queue is 5, first is always kept (displayed), overflow drops from middle
        #expect(sut.currentError?.message == "Error 0")

        // Clear all and verify queue was bounded
        var count = 0
        while sut.showError {
            count += 1
            sut.clearError()
        }
        #expect(count <= 5)
    }

    @Test("handle with context prefixes message")
    func handleWithContext() {
        let sut = makeSUT()
        sut.handle(
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection refused"]),
            context: "Server sync"
        )

        #expect(sut.currentError?.message == "Server sync: Connection refused")
    }

    @Test("showError with different severities")
    func severityLevels() {
        let sut = makeSUT()
        sut.showError("Warning message", severity: .warning)

        #expect(sut.currentError?.severity == .warning)
        #expect(sut.currentError?.message == "Warning message")
    }

    @Test("log does not show error to user")
    func logDoesNotShow() {
        let sut = makeSUT()
        sut.log(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Silent"]))

        #expect(sut.showError == false)
        #expect(sut.currentError == nil)
    }

    @Test("clearError on empty queue is safe")
    func clearEmptyQueue() {
        let sut = makeSUT()
        sut.clearError()
        sut.clearError()
        #expect(sut.showError == false)
    }
}
