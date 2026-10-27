import Foundation

package enum GatewayResponseDecoding {
    private static let maximumMethodCharacters = 160
    private static let maximumPathCharacters = 512
    private static let maximumPathComponents = 64

    package static func decode<Response: Decodable>(
        _ value: JSONValue,
        as responseType: Response.Type,
        method: String
    ) throws -> Response {
        do {
            return try value.decode(responseType)
        } catch let error as DecodingError {
            throw failure(method: method, error: error)
        }
    }

    static func failure(method: String, error: DecodingError) -> GatewayFailure {
        let diagnosis: (category: String, summary: String, path: [CodingKey])
        switch error {
        case .keyNotFound(let key, let context):
            diagnosis = ("missing_required_data", "is missing required data", context.codingPath + [key])
        case .valueNotFound(_, let context):
            diagnosis = ("missing_value", "contains a missing value", context.codingPath)
        case .typeMismatch(_, let context):
            diagnosis = ("type_mismatch", "contains data of the wrong type", context.codingPath)
        case .dataCorrupted(let context):
            diagnosis = ("invalid_data", "contains invalid data", context.codingPath)
        @unknown default:
            diagnosis = ("invalid_data", "contains invalid data", [])
        }
        let admittedMethod = String(method.prefix(maximumMethodCharacters))
        let path = admittedPath(diagnosis.path)
        let message = "The Gateway response for \(admittedMethod) \(diagnosis.summary) at \(path). Try again; if it continues, tap View Logs for details and update Tron on iPhone and the Gateway together."
        return GatewayFailure(
            code: "invalid_response",
            message: message,
            retryable: false,
            details: .object([
                "method": .string(admittedMethod),
                "category": .string(diagnosis.category),
                "codingPath": .string(path),
            ])
        )
    }

    private static func admittedPath(_ codingPath: [CodingKey]) -> String {
        let components = codingPath.prefix(maximumPathComponents).map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            // Synthesized model CodingKeys are source-owned schema names.
            // Dictionary keys are response-owned data and may contain session
            // IDs, provider values, or secrets, so never retain them in Logs.
            guard String(reflecting: type(of: key)).hasSuffix(".CodingKeys") else {
                return "<redacted>"
            }
            let admitted = key.stringValue.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                    ? Character(String(scalar)) : "?"
            }
            return String(admitted.prefix(64))
        }
        let joined = components.reduce(into: "") { result, component in
            if component.hasPrefix("[") { result += component }
            else { result += result.isEmpty ? component : ".\(component)" }
        }
        return String((joined.isEmpty ? "response" : joined).prefix(maximumPathCharacters))
    }
}
