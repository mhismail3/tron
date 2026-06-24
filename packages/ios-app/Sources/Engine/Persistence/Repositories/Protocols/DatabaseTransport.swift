import Foundation
import SQLite3

/// Protocol for async database access.
///
/// Repositories call `withDB` to execute SQLite operations on the
/// `DatabaseActor`'s background executor. The OpaquePointer never
/// leaves the actor — it is only available inside the closure.
protocol DatabaseTransport: AnyObject, Sendable {
    func withDB<T: Sendable>(_ body: @Sendable (OpaquePointer?) throws -> T) async throws -> T
}
