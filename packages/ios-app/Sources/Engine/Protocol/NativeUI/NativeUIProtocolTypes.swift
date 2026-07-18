import Foundation

/// A Sendable, lossless JSON value used by the A2UI protocol boundary.
///
/// This intentionally does not reuse `AnyCodable`: native UI definitions are
/// security-sensitive executable data and benefit from an exhaustive value
/// type that can be bounded and traversed without bridging through `Any`.
enum NativeUIJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NativeUIJSONValue])
    case object([String: NativeUIJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NativeUIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: NativeUIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported native UI JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: NativeUIJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [NativeUIJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

struct NativeUIDefinitionDTO: Codable, Equatable, Sendable {
    let schemaVersion: String
    let definitionId: String
    let catalogId: String
    let catalogRevision: UInt64
    let lifecycle: String
    let presentation: NativeUIPresentationDTO
    let messages: [NativeUIMessageDTO]
}

struct NativeUIPresentationDTO: Codable, Equatable, Sendable {
    let title: String
    let detents: [String]
    let showsDismiss: Bool
}

struct NativeUIToolbarItemDTO: Codable, Equatable, Sendable {
    let placement: String
    let label: String
    let systemImage: String?
    let action: NativeUIJSONValue?
}

struct NativeUISurfaceSnapshotDTO: Codable, Equatable, Sendable {
    var surfaceId: String
    let definitionId: String
    let definitionRevision: UInt64
    let surfaceSequence: UInt64
    let catalogId: String
    let catalogRevision: UInt64
    let lifecycle: String
    let source: String
    let presentation: NativeUIPresentationDTO
    let messages: [NativeUIMessageDTO]
    let diagnostics: [NativeUIDiagnosticDTO]
    let sessionId: String?
    let eventId: String?
}

struct NativeUIDiagnosticDTO: Codable, Equatable, Sendable {
    let code: String
    let path: String
    let message: String
}

struct NativeUIDefinitionRevisionDTO: Codable, Equatable, Sendable, Identifiable {
    let definitionId: String
    let revision: UInt64
    let parentRevision: UInt64?
    let contentHash: String
    let catalogId: String
    let catalogRevision: UInt64
    let lifecycle: String
    let status: String
    let definition: NativeUIDefinitionDTO
    let diagnostics: [NativeUIDiagnosticDTO]
    let createdAt: String

    var id: String { "\(definitionId):\(revision)" }
}

struct NativeUIValidationReportDTO: Codable, Equatable, Sendable {
    let valid: Bool
    let contentHash: String
    let diagnostics: [NativeUIDiagnosticDTO]
}

struct NativeUIMessageDTO: Codable, Equatable, Sendable {
    let version: String
    let createSurface: NativeUICreateSurfaceDTO?
    let updateComponents: NativeUIUpdateComponentsDTO?
    let updateDataModel: NativeUIUpdateDataModelDTO?
    let deleteSurface: NativeUIDeleteSurfaceDTO?

    var operationCount: Int {
        [createSurface != nil, updateComponents != nil, updateDataModel != nil, deleteSurface != nil]
            .filter { $0 }.count
    }
}

struct NativeUICreateSurfaceDTO: Codable, Equatable, Sendable {
    let surfaceId: String
    let catalogId: String
    let theme: NativeUIJSONValue?
    let sendDataModel: Bool?
}

struct NativeUIUpdateComponentsDTO: Codable, Equatable, Sendable {
    let surfaceId: String
    let components: [NativeUIComponentDTO]
}

struct NativeUIUpdateDataModelDTO: Codable, Equatable, Sendable {
    let surfaceId: String
    let path: String?
    let value: NativeUIJSONValue?
}

struct NativeUIDeleteSurfaceDTO: Codable, Equatable, Sendable {
    let surfaceId: String
}

/// One catalog component. Unknown properties remain in their canonical order-
/// independent map and are rejected by the catalog validator before rendering.
struct NativeUIComponentDTO: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let component: String
    let properties: [String: NativeUIJSONValue]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(id: String, component: String, properties: [String: NativeUIJSONValue]) {
        self.id = id
        self.component = component
        self.properties = properties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        guard let idKey = DynamicKey(stringValue: "id"),
              let componentKey = DynamicKey(stringValue: "component")
        else { throw NativeUIProtocolError.invalidComponent }
        id = try container.decode(String.self, forKey: idKey)
        component = try container.decode(String.self, forKey: componentKey)
        var decoded: [String: NativeUIJSONValue] = [:]
        for key in container.allKeys where key.stringValue != "id" && key.stringValue != "component" {
            decoded[key.stringValue] = try container.decode(NativeUIJSONValue.self, forKey: key)
        }
        properties = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        guard let idKey = DynamicKey(stringValue: "id"),
              let componentKey = DynamicKey(stringValue: "component")
        else { throw NativeUIProtocolError.invalidComponent }
        try container.encode(id, forKey: idKey)
        try container.encode(component, forKey: componentKey)
        for (name, value) in properties {
            guard let key = DynamicKey(stringValue: name) else { continue }
            try container.encode(value, forKey: key)
        }
    }
}

struct NativeUISurfaceStreamRecordDTO: Codable, Equatable, Sendable {
    let surfaceId: String
    let definitionId: String?
    let definitionRevision: UInt64?
    let catalogId: String?
    let catalogRevision: UInt64?
    let lifecycle: String?
    let sequence: UInt64
    let batchId: String
    let batchIndex: Int
    let batchCount: Int
    let isFinal: Bool
    let message: NativeUIMessageDTO
}

enum NativeUIStreamDelivery: Sendable {
    case record(NativeUISurfaceStreamRecordDTO, cursor: EngineStreamCursor)
    case recoveryRequired(reason: String)
}

struct NativeUIClientFunctionDTO: Codable, Equatable, Sendable {
    let name: String
    let revision: UInt64
    let parameters: NativeUIJSONValue
    let returnType: String
}

struct NativeUIClientCatalogDTO: Codable, Equatable, Sendable {
    let clientId: String
    let catalogId: String
    let catalogRevision: UInt64
    let functions: [NativeUIClientFunctionDTO]
}

enum NativeUIProtocolError: Error, LocalizedError {
    case invalidComponent
    case invalidBundledDefinition(String)

    var errorDescription: String? {
        switch self {
        case .invalidComponent: "Native UI component encoding is invalid"
        case .invalidBundledDefinition(let definitionId):
            "Bundled native UI definition \(definitionId) could not be loaded"
        }
    }
}
