import Foundation

public struct NativeAutomationEndpoint: Sendable, Equatable {
    public let socket: String
    public let generation: UUID
    public init(socket: String, generation: UUID) { self.socket = socket; self.generation = generation }
}
