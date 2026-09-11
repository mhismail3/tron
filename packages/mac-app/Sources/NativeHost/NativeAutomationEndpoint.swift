import Foundation

/// Read-only host-owned Cua bootstrap identity. The socket is never model- or
/// session-supplied; generation fences stale endpoints after helper restart.
public struct NativeAutomationEndpoint: Sendable, Equatable {
    public let socket: String
    public let generation: UUID
    public init(socket: String, generation: UUID) { self.socket = socket; self.generation = generation }
}
