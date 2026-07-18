import Foundation

struct NativeUISurfaceTree: Equatable, Sendable {
    private(set) var logicalSurfaceId: String?
    private(set) var catalogId: String?
    private(set) var components: [String: NativeUIComponentDTO] = [:]
    private(set) var dataModel: NativeUIJSONValue = .object([:])
    private(set) var isDeleted = false

    var root: NativeUIComponentDTO? { components["root"] }

    mutating func apply(_ message: NativeUIMessageDTO) throws {
        guard message.version == NativeUICatalog.a2uiVersion, message.operationCount == 1 else {
            throw NativeUIRuntimeError.invalidMessage("unsupported version or ambiguous operation")
        }
        if let create = message.createSurface {
            logicalSurfaceId = create.surfaceId
            catalogId = create.catalogId
            components.removeAll(keepingCapacity: true)
            dataModel = .object([:])
            isDeleted = false
        } else if let update = message.updateComponents {
            try requireSurface(update.surfaceId)
            var batchIds: Set<String> = []
            for component in update.components {
                guard batchIds.insert(component.id).inserted else {
                    throw NativeUIRuntimeError.invalidMessage(
                        "updateComponents contains duplicate id \(component.id)"
                    )
                }
                components[component.id] = component
            }
        } else if let update = message.updateDataModel {
            try requireSurface(update.surfaceId)
            guard let value = update.value else {
                throw NativeUIRuntimeError.invalidMessage("updateDataModel requires value")
            }
            try setData(value, at: update.path ?? "")
        } else if let delete = message.deleteSurface {
            try requireSurface(delete.surfaceId)
            components.removeAll()
            dataModel = .object([:])
            isDeleted = true
        }
    }

    func resolved(_ value: NativeUIJSONValue?) -> NativeUIJSONValue? {
        guard let value else { return nil }
        guard case .object(let object) = value,
              object.count == 1,
              let path = object["path"]?.stringValue
        else { return value }
        return self.value(at: path)
    }

    func value(at pointer: String) -> NativeUIJSONValue? {
        if pointer.isEmpty || pointer == "/" { return dataModel }
        guard pointer.first == "/" else { return nil }
        var current = dataModel
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let object):
                guard let next = object[token] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(token), array.indices.contains(index) else { return nil }
                current = array[index]
            default: return nil
            }
        }
        return current
    }

    /// Compact the validated candidate into a bounded canonical A2UI snapshot.
    /// This keeps streamed last-known-good caching independent of update count.
    func canonicalMessages() throws -> [NativeUIMessageDTO] {
        guard !isDeleted,
              let logicalSurfaceId,
              let catalogId
        else {
            throw NativeUIRuntimeError.invalidMessage(
                "cannot snapshot a deleted or uncreated surface"
            )
        }
        return [
            NativeUIMessageDTO(
                version: NativeUICatalog.a2uiVersion,
                createSurface: NativeUICreateSurfaceDTO(
                    surfaceId: logicalSurfaceId,
                    catalogId: catalogId,
                    theme: nil,
                    sendDataModel: nil
                ),
                updateComponents: nil,
                updateDataModel: nil,
                deleteSurface: nil
            ),
            NativeUIMessageDTO(
                version: NativeUICatalog.a2uiVersion,
                createSurface: nil,
                updateComponents: NativeUIUpdateComponentsDTO(
                    surfaceId: logicalSurfaceId,
                    components: components.values.sorted { $0.id < $1.id }
                ),
                updateDataModel: nil,
                deleteSurface: nil
            ),
            NativeUIMessageDTO(
                version: NativeUICatalog.a2uiVersion,
                createSurface: nil,
                updateComponents: nil,
                updateDataModel: NativeUIUpdateDataModelDTO(
                    surfaceId: logicalSurfaceId,
                    path: "",
                    value: dataModel
                ),
                deleteSurface: nil
            ),
        ]
    }

    mutating func setData(_ value: NativeUIJSONValue, at pointer: String) throws {
        if pointer.isEmpty || pointer == "/" {
            dataModel = value
            return
        }
        guard pointer.first == "/" else {
            throw NativeUIRuntimeError.invalidDataPath(pointer)
        }
        let tokens = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
        dataModel = try replacing(dataModel, tokens: ArraySlice(tokens), value: value)
    }

    private func replacing(
        _ current: NativeUIJSONValue,
        tokens: ArraySlice<String>,
        value: NativeUIJSONValue
    ) throws -> NativeUIJSONValue {
        guard let token = tokens.first else { return value }
        let remainder = tokens.dropFirst()
        switch current {
        case .object(var object):
            let child = object[token] ?? .object([:])
            object[token] = try replacing(child, tokens: remainder, value: value)
            return .object(object)
        case .array(var array):
            guard let index = Int(token), array.indices.contains(index) else {
                throw NativeUIRuntimeError.invalidDataPath(tokens.joined(separator: "/"))
            }
            array[index] = try replacing(array[index], tokens: remainder, value: value)
            return .array(array)
        default:
            throw NativeUIRuntimeError.invalidDataPath(tokens.joined(separator: "/"))
        }
    }

    private func requireSurface(_ surfaceId: String) throws {
        guard surfaceId == logicalSurfaceId else {
            throw NativeUIRuntimeError.surfaceMismatch(expected: logicalSurfaceId, actual: surfaceId)
        }
    }
}

enum NativeUIRuntimeError: Error, LocalizedError, Equatable {
    case invalidMessage(String)
    case surfaceMismatch(expected: String?, actual: String)
    case invalidDataPath(String)
    case invalidDefinition([NativeUIDiagnosticDTO])
    case batchRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let reason): "Invalid A2UI message: \(reason)"
        case .surfaceMismatch(let expected, let actual):
            "A2UI surface mismatch; expected \(expected ?? "none"), got \(actual)"
        case .invalidDataPath(let path): "Invalid A2UI data path \(path)"
        case .invalidDefinition(let diagnostics):
            diagnostics.first?.message ?? "Native UI definition is invalid"
        case .batchRejected(let reason): "Native UI batch rejected: \(reason)"
        }
    }
}
