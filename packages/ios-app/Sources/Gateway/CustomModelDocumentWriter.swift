import Foundation

/// Validates a complete custom-model document before replacing Pi's canonical
/// file. Validation is intentionally a separate non-mutating gateway request.
struct CustomModelDocumentWriter: Sendable {
    typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    private let request: Request
    private let put: Request?
    private let makeCommandID: @Sendable () -> String

    init(
        request: @escaping Request,
        put: Request? = nil,
        makeCommandID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.request = request
        self.put = put
        self.makeCommandID = makeCommandID
    }

    func replace(_ document: JSONValue) async throws {
        _ = try await request("models.custom.validate", .object(["document": document]))
        _ = try await (put ?? request)("models.custom.put", .object([
            "document": document,
            "commandId": .string(makeCommandID()),
        ]))
    }
}
