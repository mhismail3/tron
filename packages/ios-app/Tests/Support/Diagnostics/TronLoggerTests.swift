import Testing
import Foundation
@testable import TronMobile

@Suite("TronLogger Thread Safety")
@MainActor
struct TronLoggerTests {

    @Test("setMinimumLevel is readable")
    func setMinimumLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        logger.minimumLevel = .warning
        #expect(logger.minimumLevel == .warning)
        logger.minimumLevel = original
    }

    @Test("setCategoryLevel filters lower levels")
    func setCategoryLevel() {
        let logger = TronLogger.shared
        logger.categoryLevels[.database] = .error
        #expect(logger.categoryLevels[.database] == .error)
        logger.categoryLevels.removeValue(forKey: .database)
    }

    @Test("disableCategory prevents logging")
    func disableCategory() {
        let logger = TronLogger.shared
        let wasEnabled = logger.enabledCategories.contains(.database)
        logger.disableCategory(.database)
        #expect(!logger.enabledCategories.contains(.database))
        if wasEnabled {
            logger.enableCategory(.database)
        }
    }
}

@Suite("TronLogger Level Filtering")
@MainActor
struct TronLoggerLevelFilteringTests {

    @Test("default minimumLevel is verbose in debug builds")
    func defaultMinimumLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer { logger.minimumLevel = original }
        // In debug builds (test runner), default should be .verbose
        #expect(original == .verbose)
    }

    @Test("verbose messages are buffered when minimumLevel is verbose")
    func verboseBufferedAtVerboseLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.database)
        logger.verbose("test verbose message", category: .database)

        let logs = logger.getRecentLogs(category: .database)
        #expect(logs.count == 1)
        #expect(logs.first?.3 == "test verbose message")
    }

    @Test("verbose messages are NOT buffered when minimumLevel is info")
    func verboseFilteredAtInfoLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .info
        logger.clearBufferForCategory(.database)
        logger.verbose("should not appear", category: .database)

        let logs = logger.getRecentLogs(category: .database)
        #expect(logs.isEmpty)
    }

    @Test("debug messages are NOT buffered when minimumLevel is info")
    func debugFilteredAtInfoLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .info
        logger.clearBufferForCategory(.database)
        logger.debug("should not appear", category: .database)

        let logs = logger.getRecentLogs(category: .database)
        #expect(logs.isEmpty)
    }

    @Test("info messages ARE buffered when minimumLevel is info")
    func infoPassesAtInfoLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .info
        logger.clearBufferForCategory(.database)
        logger.info("info message", category: .database)

        let logs = logger.getRecentLogs(category: .database)
        #expect(logs.count == 1)
    }

    @Test("message closure is not evaluated when level is filtered")
    func autoclosureDefersEvaluation() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .error
        logger.clearBufferForCategory(.database)

        // Use a class to track side effects since nonisolated(unsafe) is needed
        // for capture in @autoclosure across isolation boundaries
        nonisolated(unsafe) var evaluated = false
        func expensiveString() -> String {
            evaluated = true
            return "expensive computation"
        }

        logger.verbose(expensiveString(), category: .database)
        #expect(!evaluated, "Message closure should not be evaluated when level is filtered")
    }

    @Test("message closure IS evaluated when level passes")
    func autoclosureEvaluatesWhenPassing() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        defer {
            logger.minimumLevel = original
            logger.clearBufferForCategory(.database)
        }

        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.database)

        nonisolated(unsafe) var evaluated = false
        func expensiveString() -> String {
            evaluated = true
            return "result"
        }

        logger.verbose(expensiveString(), category: .database)
        #expect(evaluated, "Message closure should be evaluated when level passes")
    }
}

@Suite("TronLogger Sensitive Data Guards")
@MainActor
struct TronLoggerSensitiveDataTests {

    @Test("Engine request logging never buffers raw payload")
    func engineRequestLoggingOmitsRawPayload() {
        let logger = TronLogger.shared
        let originalLevel = logger.minimumLevel
        defer {
            logger.minimumLevel = originalLevel
            logger.clearBufferForCategory(.engine)
        }

        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.engine)

        logger.logEngineRequest(
            functionId: "auth::update",
            payload: #"{"apiKey":"sk-test-abcdefghijklmnopqrstuvwxyz","apiKeyLabel":"Project"}"#,
            id: "42"
        )

        let message = logger.getRecentLogs(category: .engine).last?.3 ?? ""
        #expect(message.contains("auth::update"))
        #expect(message.contains("[42]"))
        #expect(!message.contains("sk-test-abcdefghijklmnopqrstuvwxyz"))
        #expect(!message.contains("apiKeyLabel"))
        #expect(!message.contains("Project"))
    }

    @Test("WebSocket message logging never buffers JSON previews")
    func websocketMessageLoggingOmitsPreview() {
        let logger = TronLogger.shared
        let originalLevel = logger.minimumLevel
        defer {
            logger.minimumLevel = originalLevel
            logger.clearBufferForCategory(.websocket)
        }

        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.websocket)

        logger.logWebSocketMessage(
            direction: "→ SEND",
            type: "auth.addApiKey",
            size: 123
        )

        let message = logger.getRecentLogs(category: .websocket).last?.3 ?? ""
        #expect(message.contains("→ SEND"))
        #expect(message.contains("auth.addApiKey"))
        #expect(message.contains("123 bytes"))
        #expect(!message.contains("sk-test-abcdefghijklmnopqrstuvwxyz"))
        #expect(!message.contains("apiKeyLabel"))
        #expect(!message.contains("Project"))
    }

    @Test("event logging admits metadata but has no payload input")
    func eventLoggingRecordsOnlyMetadata() {
        let logger = TronLogger.shared
        let originalLevel = logger.minimumLevel
        defer {
            logger.minimumLevel = originalLevel
            logger.clearBufferForCategory(.events)
        }

        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.events)
        logger.logEvent(
            type: "notification.received",
            sessionId: "session-private-suffix",
            payloadBytes: 4_096
        )

        let message = logger.getRecentLogs(category: .events).last?.3 ?? ""
        #expect(message.contains("notification.received"))
        #expect(message.contains("session-..."))
        #expect(message.contains("payloadBytes=4096"))
        #expect(!message.contains("private-suffix"))
    }

    @Test("Malformed inbound frames never enter diagnostics verbatim")
    func malformedInboundFrameLoggingOmitsContent() async {
        let logger = TronLogger.shared
        let originalLevel = logger.minimumLevel
        defer {
            logger.minimumLevel = originalLevel
            logger.clearBufferForCategory(.websocket)
        }
        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.websocket)
        let sentinel = "private-notification-body-sentinel"
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )

        await connection.handleMessage(Data(sentinel.utf8))

        let messages = logger.getRecentLogs(category: .websocket).map(\.3)
        #expect(messages.contains { $0.contains("malformed non-JSON") })
        #expect(!messages.contains { $0.contains(sentinel) })
    }
}

@Suite("TronLogger Bounded Storage")
@MainActor
struct TronLoggerBoundedStorageTests {
    @Test("Chatty transport logging keeps only the fixed ring capacity")
    func websocketRingRemainsBounded() {
        let logger = TronLogger.shared
        let originalLevel = logger.minimumLevel
        defer {
            logger.minimumLevel = originalLevel
            logger.clearBufferForCategory(.websocket)
        }
        logger.minimumLevel = .verbose
        logger.clearBufferForCategory(.websocket)

        for index in 0..<1_500 {
            logger.verbose("frame \(index)", category: .websocket)
        }

        let logs = logger.getRecentLogs(count: 2_000, category: .websocket)
        #expect(logs.count == 1_000)
        #expect(logs.first?.3 == "frame 500")
        #expect(logs.last?.3 == "frame 1499")
    }
}
