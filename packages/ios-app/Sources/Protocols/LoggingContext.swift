import Foundation

/// Base protocol providing logging capabilities for all context protocols.
/// Coordinators use these methods to log events without coupling to a specific logger.
@MainActor
protocol LoggingContext: AnyObject {
    func logVerbose(_ message: String)
    func logDebug(_ message: String)
    func logInfo(_ message: String)
    func logWarning(_ message: String)
    func logError(_ message: String)
}
