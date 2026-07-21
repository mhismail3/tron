import Foundation

/// Content-block discriminators shared by durable messages and the live stream.
enum ContentBlockType: String {
    case text
    case image
    case document
    case capabilityInvocation = "capability_invocation"
    case capabilityResult = "capability_result"
    case thinking
}

/// Model capability lifecycle states restored into the live timeline.
enum CapabilityInvocationStatusDTO: String {
    case generating
    case running
    case paused
    case completed
    case error
}

/// Provider stop reasons stored with assistant messages.
enum StopReason: String {
    case endTurn = "end_turn"
    case capabilityInvocation = "capability_invocation"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
}
