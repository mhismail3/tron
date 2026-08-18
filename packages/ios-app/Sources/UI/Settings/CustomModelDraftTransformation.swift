import Foundation

struct CustomModelProviderDraft: Identifiable, Hashable, Sendable {
    let id: UUID
    var identifier: String
    var baseURL: String
    var api: String
    var models: String
    var original: [String: JSONValue]

    init(
        id: UUID = UUID(),
        identifier: String = "",
        baseURL: String = "",
        api: String = "openai-completions",
        models: String = "",
        original: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.identifier = identifier
        self.baseURL = baseURL
        self.api = api
        self.models = models
        self.original = original
    }
}

struct PreparedCustomModelDraft: Sendable {
    let root: [String: JSONValue]
    let providers: [CustomModelProviderDraft]
    let document: String
}

struct RenderedCustomModelDraft: Sendable {
    let root: [String: JSONValue]
    let value: JSONValue
    let document: String
}

enum CustomModelDraftTransformationError: LocalizedError {
    case invalidRoot
    case invalidProviders
    case invalidProvider(String)
    case invalidModels(String)
    case duplicateProviderIdentifier(String)
    case duplicateModelIdentifier(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "Advanced JSON must have an object at the top level."
        case .invalidProviders:
            "Advanced JSON must contain a providers object."
        case .invalidProvider(let identifier):
            "Provider \(identifier) must be an object with string baseUrl and api values."
        case .invalidModels(let identifier):
            "Provider \(identifier) must contain models with unique string IDs."
        case .duplicateProviderIdentifier(let identifier):
            "More than one provider resolves to the identifier \(identifier)."
        case .duplicateModelIdentifier(let provider, let identifier):
            "Provider \(provider) contains the model ID \(identifier) more than once."
        }
    }
}

enum CustomModelDraftTransformation {
    static func decodeAdvanced(_ document: String) throws -> PreparedCustomModelDraft {
        guard let data = document.data(using: .utf8) else {
            throw CustomModelDraftTransformationError.invalidRoot
        }
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        return try prepare(value)
    }

    static func prepare(_ value: JSONValue) throws -> PreparedCustomModelDraft {
        guard let root = value.objectValue else {
            throw CustomModelDraftTransformationError.invalidRoot
        }
        guard let providerValues = root["providers"]?.objectValue else {
            throw CustomModelDraftTransformationError.invalidProviders
        }
        let providers = try providerValues.sorted(by: { $0.key < $1.key }).map { identifier, value in
            try Task.checkCancellation()
            guard let object = value.objectValue,
                  object["baseUrl"].map({ $0.stringValue != nil }) ?? true,
                  object["api"].map({ $0.stringValue != nil }) ?? true else {
                throw CustomModelDraftTransformationError.invalidProvider(identifier)
            }
            let models: String
            if let modelValues = object["models"] {
                guard let values = modelValues.arrayValue else {
                    throw CustomModelDraftTransformationError.invalidModels(identifier)
                }
                var identities = Set<String>()
                var modelIDs: [String] = []
                modelIDs.reserveCapacity(values.count)
                for model in values {
                    guard let id = model.objectValue?["id"]?.stringValue,
                          !id.isEmpty,
                          identities.insert(id).inserted else {
                        throw CustomModelDraftTransformationError.invalidModels(identifier)
                    }
                    modelIDs.append(id)
                }
                models = modelIDs.joined(separator: "\n")
            } else {
                models = ""
            }
            return CustomModelProviderDraft(
                identifier: identifier,
                baseURL: object["baseUrl"]?.stringValue ?? "",
                api: object["api"]?.stringValue ?? "",
                models: models,
                original: object
            )
        }
        return PreparedCustomModelDraft(
            root: root,
            providers: providers,
            document: value.prettyPrinted
        )
    }

    static func rebuild(
        root: [String: JSONValue],
        providers: [CustomModelProviderDraft]
    ) throws -> RenderedCustomModelDraft {
        var providerValues: [String: JSONValue] = [:]
        providerValues.reserveCapacity(providers.count)
        var providerIdentities = Set<String>()
        for provider in providers {
            try Task.checkCancellation()
            let identifier = provider.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            guard providerIdentities.insert(identifier).inserted else {
                throw CustomModelDraftTransformationError.duplicateProviderIdentifier(identifier)
            }
            var object = provider.original
            if provider.api.isEmpty { object.removeValue(forKey: "api") }
            else { object["api"] = .string(provider.api) }
            if provider.baseURL.isEmpty { object.removeValue(forKey: "baseUrl") }
            else { object["baseUrl"] = .string(provider.baseURL) }
            let ids = provider.models
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var modelIdentities = Set<String>()
            for id in ids where !modelIdentities.insert(id).inserted {
                throw CustomModelDraftTransformationError.duplicateModelIdentifier(identifier, id)
            }
            let existingModels = (object["models"]?.arrayValue ?? []).reduce(into: [String: JSONValue]()) { result, value in
                if let id = value.objectValue?["id"]?.stringValue { result[id] = value }
            }
            if ids.isEmpty {
                object.removeValue(forKey: "models")
            } else {
                object["models"] = .array(ids.map { id in
                    existingModels[id] ?? .object(["id": .string(id), "name": .string(id)])
                })
            }
            providerValues[identifier] = .object(object)
        }
        var updatedRoot = root
        updatedRoot["providers"] = .object(providerValues)
        let value = JSONValue.object(updatedRoot)
        return RenderedCustomModelDraft(root: updatedRoot, value: value, document: value.prettyPrinted)
    }
}
