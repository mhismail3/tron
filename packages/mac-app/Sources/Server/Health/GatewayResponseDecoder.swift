import Foundation

/// One reader for the Gateway's response envelope, `{type, id, ok, result, error}`.
///
/// The wrapper's clients differ in what a result must decode to, what an error
/// means to them and what they tell the user, so those stay with each client.
/// This decoder owns only what every client must agree on: the frame parses as a
/// JSON object, it addresses the expected request ID, its `type` is `response`,
/// and `ok` is a boolean. Undeclared fields are tolerated, because the Gateway
/// adds response fields without a protocol bump.
///
/// A response that carries both a result and an error, or `ok: true` with an
/// error, is malformed: the Gateway sends exactly one of the two
/// (`packages/gateway/src/transport/server.ts`), and no client should have to
/// guess which half is authoritative.
enum GatewayResponseDecoder {
    /// The `error` object of a failed response. Only the members the Mac wrapper
    /// reads are modelled.
    struct ErrorFrame: Decodable, Equatable, Sendable {
        var code: String?
        var message: String?
        var retryable: Bool?
    }

    enum Frame<Payload> {
        /// Not a response, or a response addressed to another request ID.
        case ignore
        /// `ok` with a decodable result.
        case result(Payload)
        /// Not `ok`, with the response's error object when it decoded.
        case error(ErrorFrame?)
        /// A response addressed to this request with an unusable envelope or result.
        case malformed
    }

    static func decode<Payload: Decodable>(data: Data, expectedID: String) -> Frame<Payload> {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        // Compare the request ID before the envelope shape: an unrelated frame
        // (an event, or another request's response) must not end the caller's
        // bounded receive loop.
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
