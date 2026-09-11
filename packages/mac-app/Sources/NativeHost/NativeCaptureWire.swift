import Foundation

enum NativeCaptureHostError: String, Error, Sendable {
    case invalidRequest, unauthorized, stale, busy, exhausted, unavailable, retirementFailed
}

struct NativeCaptureRequest: Decodable, Equatable, Sendable {
    let version: Int
    let operation: String
    /// Control commands have receipts; disposable pulls use readSequence only.
    let commandID: UUID?
    let loadID: UUID
    let bootID: UUID?
    let connectionID: UUID?
    let sessionID: UUID?
    let handle: UUID?
    let generation: UUID?
    let readSequence: UInt64?

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeCaptureHostError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        var keys: Set<String> = ["version", "operation", "loadID"]
        if request.operation != "pull" { keys.insert("commandID") }
        if request.operation != "hello" { keys.formUnion(["bootID", "connectionID", "sessionID"]) }
        switch request.operation {
        case "hello", "catalog", "suspend", "stop": break
        case "start": keys.insert("handle")
        case "pull": keys.formUnion(["generation", "readSequence"])
        default: throw NativeCaptureHostError.invalidRequest
        }
        guard request.version == 1, Set(object.keys) == keys,
              (request.operation == "pull" ? request.commandID == nil : request.commandID != nil),
              request.operation == "hello" || (request.bootID != nil && request.connectionID != nil && request.sessionID != nil),
              request.operation != "start" || request.handle != nil,
              request.operation != "pull" || (request.generation != nil && (1...9_007_199_254_740_991).contains(request.readSequence ?? 0)) else {
            throw NativeCaptureHostError.invalidRequest
        }
        return request
    }
}

struct NativeCaptureResponse: Sendable {
    let control: Data
    let jpeg: Data?
    static func error(_ error: NativeCaptureHostError) -> Self {
        Self(control: Data("{\"version\":1,\"status\":\"\(error.rawValue)\"}".utf8), jpeg: nil)
    }
}
