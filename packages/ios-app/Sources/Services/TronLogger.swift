import Foundation
import os

// MARK: - Log Level

enum LogLevel: Int, Comparable, CaseIterable {
    case verbose = 0  // Everything, very noisy
    case debug = 1    // Detailed debugging info
    case info = 2     // General operational info
    case warning = 3  // Potential issues
    case error = 4    // Errors that need attention
    case none = 5     // Disable logging

    var prefix: String {
        switch self {
        case .verbose: return "📝 VERBOSE"
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARNING"
        case .error: return "❌ ERROR"
        case .none: return ""
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .verbose, .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .none: return .debug
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Log Category

enum LogCategory: String, CaseIterable {
    case websocket = "WebSocket"
    case rpc = "RPC"
    case session = "Session"
    case chat = "Chat"
    case ui = "UI"
    case network = "Network"
    case events = "Events"
    case general = "General"

    var subsystem: String { "com.tron.mobile" }
}

// MARK: - Tron Logger

final class TronLogger: @unchecked Sendable {
    static let shared = TronLogger()

    // Current minimum log level (can be changed at runtime)
    var minimumLevel: LogLevel = .verbose

    // Category-specific log levels (optional override)
    var categoryLevels: [LogCategory: LogLevel] = [:]

    // Enable/disable categories entirely
    var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)

    // In-memory log buffer for viewing in-app
    private var logBuffer: [(Date, LogCategory, LogLevel, String)] = []
    private let maxBufferSize = 1000
    private let bufferLock = NSLock()

    // OS Loggers by category
    private var loggers: [LogCategory: Logger] = [:]

    private init() {
        // Initialize loggers for each category
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: category.subsystem, category: category.rawValue)
        }
    }

    // MARK: - Configuration

    func setLevel(_ level: LogLevel) {
        minimumLevel = level
        log(.info, category: .general, "Log level set to \(level)")
    }

    func setLevel(_ level: LogLevel, for category: LogCategory) {
        categoryLevels[category] = level
        log(.info, category: .general, "Log level for \(category.rawValue) set to \(level)")
    }

    func enableCategory(_ category: LogCategory) {
        enabledCategories.insert(category)
    }

    func disableCategory(_ category: LogCategory) {
        enabledCategories.remove(category)
    }

    // MARK: - Logging Methods

    func log(_ level: LogLevel, category: LogCategory = .general, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        // Check if category is enabled
        guard enabledCategories.contains(category) else { return }

        // Check log level (category-specific or global)
        let effectiveLevel = categoryLevels[category] ?? minimumLevel
        guard level >= effectiveLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedMessage = "[\(timestamp)] \(level.prefix) [\(category.rawValue)] \(fileName):\(line) \(function) - \(message)"

        // Log to OS unified logging
        loggers[category]?.log(level: level.osLogType, "\(formattedMessage)")

        // Also print to console for Xcode debugging
        print(formattedMessage)

        // Add to in-memory buffer
        bufferLock.lock()
        logBuffer.append((Date(), category, level, message))
        if logBuffer.count > maxBufferSize {
            logBuffer.removeFirst(logBuffer.count - maxBufferSize)
        }
        bufferLock.unlock()
    }

    // Convenience methods
    func verbose(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.verbose, category: category, message, file: file, function: function, line: line)
    }

    func debug(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, category: category, message, file: file, function: function, line: line)
    }

    func info(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }

    func warning(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }

    func error(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }

    // MARK: - Specialized Logging

    func logRPCRequest(method: String, params: Any?, id: Int) {
        let paramsStr = params.map { String(describing: $0).prefix(500) } ?? "nil"
        verbose("→ RPC Request [\(id)] \(method): \(paramsStr)", category: .rpc)
    }

    func logRPCResponse(method: String, id: Int, success: Bool, duration: TimeInterval, result: Any? = nil, error: String? = nil) {
        let durationMs = String(format: "%.1fms", duration * 1000)
        if success {
            let resultStr = result.map { String(describing: $0).prefix(500) } ?? "nil"
            debug("← RPC Response [\(id)] \(method) ✓ (\(durationMs)): \(resultStr)", category: .rpc)
        } else {
            self.error("← RPC Response [\(id)] \(method) ✗ (\(durationMs)): \(error ?? "unknown error")", category: .rpc)
        }
    }

    func logWebSocketState(_ state: String, details: String? = nil) {
        let msg = details.map { "\(state): \($0)" } ?? state
        info(msg, category: .websocket)
    }

    func logWebSocketMessage(direction: String, type: String, size: Int, preview: String? = nil) {
        var msg = "\(direction) [\(type)] \(size) bytes"
        if let preview = preview {
            msg += " - \(preview.prefix(200))"
        }
        verbose(msg, category: .websocket)
    }

    func logEvent(type: String, sessionId: String?, data: String? = nil) {
        var msg = "Event: \(type)"
        if let sid = sessionId {
            msg += " [session: \(sid.prefix(8))...]"
        }
        if let data = data {
            msg += " - \(data.prefix(300))"
        }
        debug(msg, category: .events)
    }

    func logUIAction(_ action: String, details: String? = nil) {
        let msg = details.map { "\(action): \($0)" } ?? action
        verbose(msg, category: .ui)
    }

    // MARK: - Buffer Access

    func getRecentLogs(count: Int = 100, level: LogLevel? = nil, category: LogCategory? = nil) -> [(Date, LogCategory, LogLevel, String)] {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        var filtered = logBuffer

        if let level = level {
            filtered = filtered.filter { $0.2 >= level }
        }

        if let category = category {
            filtered = filtered.filter { $0.1 == category }
        }

        return Array(filtered.suffix(count))
    }

    func clearBuffer() {
        bufferLock.lock()
        logBuffer.removeAll()
        bufferLock.unlock()
    }

    func exportLogs() -> String {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return logBuffer.map { entry in
            let (date, category, level, message) = entry
            return "[\(formatter.string(from: date))] \(level.prefix) [\(category.rawValue)] \(message)"
        }.joined(separator: "\n")
    }
}

// MARK: - Global Convenience

let logger = TronLogger.shared
