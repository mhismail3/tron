import Foundation
import UIKit

/// Executes only functions compiled into this iOS binary. Picker-like functions
/// are surfaced as typed requests and completed by `NativeUISurfaceView`.
@Observable
@MainActor
final class NativeUIClientBridge {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let arguments: [String: NativeUIJSONValue]

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    enum BridgeError: Error, LocalizedError {
        case unsupported(String)
        case requestAlreadyActive
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "Native function \(name) is unavailable"
            case .requestAlreadyActive: "Another native picker is already active"
            case .cancelled: "Native function was cancelled"
            }
        }
    }

    private(set) var pendingRequest: Request?
    private var continuation: CheckedContinuation<NativeUIJSONValue, Error>?
    var dismiss: (() async -> Void)?
    var navigate: ((String) async throws -> NativeUIJSONValue)?

    func execute(name: String, arguments: [String: NativeUIJSONValue]) async throws -> NativeUIJSONValue {
        switch name {
        case "copy":
            guard let text = arguments["text"]?.stringValue else { throw BridgeError.unsupported(name) }
            UIPasteboard.general.string = text
            return .null
        case "dismiss":
            await dismiss?()
            return .null
        case "openUrl":
            guard let raw = arguments["url"]?.stringValue,
                  let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { throw BridgeError.unsupported(name) }
            guard await UIApplication.shared.open(url) else { throw BridgeError.cancelled }
            return .null
        case "navigate":
            guard let destination = arguments["destination"]?.stringValue,
                  let navigate
            else { throw BridgeError.unsupported(name) }
            return try await navigate(destination)
        case "resourcePicker", "filePicker", "camera":
            guard pendingRequest == nil, continuation == nil else {
                throw BridgeError.requestAlreadyActive
            }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                pendingRequest = Request(name: name, arguments: arguments)
            }
        default:
            throw BridgeError.unsupported(name)
        }
    }

    func complete(_ value: NativeUIJSONValue) {
        let continuation = continuation
        self.continuation = nil
        pendingRequest = nil
        continuation?.resume(returning: value)
    }

    func cancel() {
        let continuation = continuation
        self.continuation = nil
        pendingRequest = nil
        continuation?.resume(throwing: BridgeError.cancelled)
    }

    static func catalog(clientId: String) -> NativeUIClientCatalogDTO {
        NativeUIClientCatalogDTO(
            clientId: clientId,
            catalogId: NativeUICatalog.id,
            catalogRevision: NativeUICatalog.revision,
            functions: [
                function("dismiss", parameters: objectSchema()),
                function("navigate", parameters: objectSchema(
                    required: ["destination"],
                    properties: ["destination": stringSchema(minLength: 1)]
                ), returnType: "object"),
                function("copy", parameters: objectSchema(
                    required: ["text"],
                    properties: ["text": stringSchema(maxLength: 16_384)]
                )),
                function("openUrl", parameters: objectSchema(
                    required: ["url"],
                    properties: ["url": stringSchema(minLength: 1, maxLength: 2_048)]
                )),
                function("resourcePicker", parameters: objectSchema(
                    required: ["kind"],
                    properties: [
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array([.string("workspace"), .string("model")]),
                        ]),
                        "selected": .object([
                            "type": .array([.string("string"), .string("null")]),
                        ]),
                    ]
                ), returnType: "object"),
                function("filePicker", parameters: objectSchema(properties: [
                    "contentTypes": .object([
                        "type": .string("array"),
                        "maxItems": .number(32),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "allowsMultiple": .object(["type": .string("boolean")]),
                ]), returnType: "object"),
                function("camera", parameters: objectSchema(properties: [
                    "mediaType": .object([
                        "type": .string("string"),
                        "enum": .array([.string("photo"), .string("video")]),
                    ]),
                ]), returnType: "object"),
            ]
        )
    }

    private static func function(
        _ name: String,
        parameters: NativeUIJSONValue,
        returnType: String = "null"
    ) -> NativeUIClientFunctionDTO {
        .init(name: name, revision: 1, parameters: parameters, returnType: returnType)
    }

    private static func objectSchema(
        required: [String] = [],
        properties: [String: NativeUIJSONValue] = [:]
    ) -> NativeUIJSONValue {
        var schema: [String: NativeUIJSONValue] = [
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(NativeUIJSONValue.string)) }
        if !properties.isEmpty { schema["properties"] = .object(properties) }
        return .object(schema)
    }

    private static func stringSchema(
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) -> NativeUIJSONValue {
        var schema: [String: NativeUIJSONValue] = ["type": .string("string")]
        if let minLength { schema["minLength"] = .number(Double(minLength)) }
        if let maxLength { schema["maxLength"] = .number(Double(maxLength)) }
        return .object(schema)
    }
}

enum NativeUIClientIdentity {
    static func persistent(defaults: UserDefaults = .standard) -> String {
        let key = "nativeUI.clientId"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
}
