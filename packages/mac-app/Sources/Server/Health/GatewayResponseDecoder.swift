import Foundation

enum GatewayResponseDecoder {
    struct ErrorFrame: Decodable, Equatable, Sendable {
        var code: String?
        var message: String?
        var retryable: Bool?
    }

    enum Frame<Payload> {
        case ignore
        case result(Payload)
        case error(ErrorFrame?)
        case malformed
    }

    static func decode<Payload: Decodable>(data: Data, expectedID: String) -> Frame<Payload> {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard frame["id"] as? String == expectedID else { return .ignore }
        guard let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data),
              envelope.type == "response" else {
            return .malformed
        }
        guard envelope.ok else {
            return envelope.result == nil ? .error(envelope.error) : .malformed
        }
        guard envelope.error == nil, let result = envelope.result else { return .malformed }
        return .result(result)
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        var type: String
        var ok: Bool
        var result: Payload?
        var error: ErrorFrame?
    }
}
