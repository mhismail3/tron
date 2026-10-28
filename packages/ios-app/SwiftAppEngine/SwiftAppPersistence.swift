import Foundation
import Observation

/// One bounded JSON value handed to the installed app's mutation owner.
package struct SwiftAppPersistenceWrite {
    package let key: String
    package let value: Data
}

@MainActor @Observable
final class SwiftAppPersistenceSlot {
    let key: String
    let signature: String
    let collection: Bool
    var value: SwiftAppValue

    init(key: String, signature: String, collection: Bool, value: SwiftAppValue) {
        self.key = key
        self.signature = signature
        self.collection = collection
        self.value = value
    }
}

/// The installed app's loaded state projection. The host owns transport,
/// revision checks, receipts and unsaved-write presentation; the interpreter
/// emits a batch only after its synchronous action commits. No UserDefaults,
/// disk, network or ambient installed-app identity enters the interpreter.
@MainActor
package final class SwiftAppPersistence {
    private var entries: [String: Data]
    private var slots: [String: SwiftAppPersistenceSlot] = [:]
    private var admitted = false
    private let committed: ([SwiftAppPersistenceWrite]) -> Void

    package init(entries: [String: Data], committed: @escaping ([SwiftAppPersistenceWrite]) -> Void) {
        self.entries = entries
        self.committed = committed
    }

    func slot(key: String, collection: Bool, initial: SwiftAppValue, program: SwiftAppProgramSyntax) throws -> SwiftAppPersistenceSlot {
        try admitSnapshot()
        try Self.admitKey(key)
        let signature: String
        switch (collection, initial.resolved) {
        case (false, .int): signature = "Int"
        case (false, .double): signature = "Double"
        case (false, .bool): signature = "Bool"
        case (false, .string): signature = "String"
        case (true, .array): signature = "Array"
        case (true, .dictionary): signature = "Dictionary"
        default: throw SwiftAppRuntimeError(collection
            ? "@Persisted needs an array or dictionary default"
            : "@AppStorage needs a Bool, Int, Double or String default")
        }
        if let slot = slots[key] {
            guard slot.signature == signature, slot.collection == collection else {
                throw SwiftAppRuntimeError("Persistent key '\(key)' has incompatible declarations")
            }
            return slot
        }
        let restored: SwiftAppValue
        if let data = entries[key] {
            do {
                if collection {
                    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                    guard envelope.version == 1 else { throw SwiftAppRuntimeError("Unknown persisted collection format") }
                    restored = try envelope.value.restore(program: program)
                    switch (initial.resolved, restored) {
                    case (.array, .array), (.dictionary, .dictionary): break
                    default: throw SwiftAppRuntimeError("Stored collection has a different kind")
                    }
                } else {
                    switch initial.resolved {
                    case .int: restored = .int(try JSONDecoder().decode(Int.self, from: data))
                    case .double: restored = .double(try JSONDecoder().decode(Double.self, from: data))
                    case .bool: restored = .bool(try JSONDecoder().decode(Bool.self, from: data))
                    case .string: restored = .string(try JSONDecoder().decode(String.self, from: data))
                    default: throw SwiftAppRuntimeError("Invalid scalar default")
                    }
                }
            } catch {
                throw SwiftAppRuntimeError("Stored value for '\(key)' cannot be restored: \(error)")
            }
        } else {
            restored = initial.resolved
        }
        let slot = SwiftAppPersistenceSlot(key: key, signature: signature, collection: collection, value: restored)
        // Defaults must be serializable too, but opening an app never writes them.
        try Self.admitJSON(encode(slot, program: program))
        slots[key] = slot
        return slot
    }

    func writes(for keys: Set<String>, program: SwiftAppProgramSyntax) throws -> [SwiftAppPersistenceWrite] {
        guard !keys.isEmpty else { return [] }
        guard keys.count <= 256 else { throw SwiftAppRuntimeError("An action may persist at most 256 keys") }
        var next = entries
        let writes = try keys.sorted().map { key in
            guard let slot = slots[key] else { throw SwiftAppRuntimeError("Unknown persistent key") }
            let data = try encode(slot, program: program)
            try Self.admitJSON(data)
            next[key] = data
            return SwiftAppPersistenceWrite(key: key, value: data)
        }
        guard next.count <= 1_000, next.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= 512 * 1_024 else {
            throw SwiftAppRuntimeError("The app's persistent state exceeds its 1,000-key or 512 KB limit")
        }
        return writes
    }

    func publish(_ writes: [SwiftAppPersistenceWrite]) {
        guard !writes.isEmpty else { return }
        for write in writes { entries[write.key] = write.value }
        committed(writes)
    }

    private func encode(_ slot: SwiftAppPersistenceSlot, program: SwiftAppProgramSyntax) throws -> Data {
        let encoder = JSONEncoder()
        if slot.collection {
            switch slot.value.resolved {
            case .array where slot.signature == "Array", .dictionary where slot.signature == "Dictionary": break
            default: throw SwiftAppRuntimeError("Persistent key '\(slot.key)' changed its collection kind")
            }
            return try encoder.encode(Envelope(version: 1, value: StoredValue(slot.value, program: program)))
        }
        switch slot.value.resolved {
        case .int(let value) where slot.signature == "Int": return try encoder.encode(Self.admitInteger(value))
        case .double(let value) where slot.signature == "Double": return try encoder.encode(value)
        case .bool(let value) where slot.signature == "Bool": return try encoder.encode(value)
        case .string(let value) where slot.signature == "String": return try encoder.encode(value)
        default: throw SwiftAppRuntimeError("Persistent key '\(slot.key)' changed its scalar type")
        }
    }

    private func admitSnapshot() throws {
        guard !admitted else { return }
        guard entries.count <= 1_000, entries.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= 512 * 1_024 else {
            throw SwiftAppRuntimeError("The app's persistent snapshot exceeds its bounds")
        }
        for (key, data) in entries { try Self.admitKey(key); try Self.admitJSON(data) }
        admitted = true
    }

    private static func admitInteger(_ value: Int) throws -> Int {
        guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) else {
            throw SwiftAppRuntimeError("Persistent integers must fit JSON's exact 53-bit range")
        }
        return value
    }

    private static func admitKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 256,
              !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw SwiftAppRuntimeError("Persistent keys must be 1–256 UTF-8 bytes without control characters")
        }
    }

    private static func admitJSON(_ data: Data) throws {
        guard data.count <= 256 * 1_024 else { throw SwiftAppRuntimeError("A persistent value exceeds 256 KB") }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        func walk(_ object: Any, depth: Int) throws {
            guard depth <= 32 else { throw SwiftAppRuntimeError("Persistent JSON exceeds 32 levels") }
            if let values = object as? [Any] { for value in values { try walk(value, depth: depth + 1) } }
            if let values = object as? [String: Any] { for value in values.values { try walk(value, depth: depth + 1) } }
        }
        try walk(object, depth: 0)
    }

    private struct Envelope: Codable { let version: Int; let value: StoredValue }
    private struct Pair: Codable { let key: StoredValue; let value: StoredValue }

    /// Typed values avoid guessing whether a JSON object is a dictionary or a
    /// struct, and retain Int/Double identity, dictionary keys and struct names.
    private indirect enum StoredValue: Codable {
        case null, bool(Bool), integer(Int), double(Double), string(String)
        case array([StoredValue]), dictionary([Pair]), record(String, [String: StoredValue])

        @MainActor
        init(_ value: SwiftAppValue, program: SwiftAppProgramSyntax, depth: Int = 0) throws {
            guard depth <= 32 else { throw SwiftAppRuntimeError("Persistent values exceed 32 levels") }
            switch value.resolved {
            case .nilValue: self = .null
            case .bool(let value): self = .bool(value)
            case .int(let value): self = .integer(try SwiftAppPersistence.admitInteger(value))
            case .double(let value) where value.isFinite: self = .double(value)
            case .string(let value): self = .string(value)
            case .array(let values): self = .array(try values.map { try StoredValue($0, program: program, depth: depth + 1) })
            case .dictionary(let entries):
                self = .dictionary(try entries.map { Pair(key: try StoredValue($0.0.value, program: program, depth: depth + 1), value: try StoredValue($0.1, program: program, depth: depth + 1)) })
            case .record(let record):
                try Self.admitRecord(record.typeName, fields: Set(record.fields.keys), program: program)
                self = .record(record.typeName, try record.fields.mapValues { try StoredValue($0, program: program, depth: depth + 1) })
            default: throw SwiftAppRuntimeError("@Persisted supports only finite JSON scalars, arrays, dictionaries and value structs; not objects, closures, bindings or native values")
            }
        }

        @MainActor
        func restore(program: SwiftAppProgramSyntax, depth: Int = 0) throws -> SwiftAppValue {
            guard depth <= 32 else { throw SwiftAppRuntimeError("Persistent values exceed 32 levels") }
            switch self {
            case .null: return .nilValue
            case .bool(let value): return .bool(value)
            case .integer(let value): return .int(try SwiftAppPersistence.admitInteger(value))
            case .double(let value):
                guard value.isFinite else { throw SwiftAppRuntimeError("Persistent numbers must be finite") }
                return .double(value)
            case .string(let value): return .string(value)
            case .array(let values): return .array(try values.map { try $0.restore(program: program, depth: depth + 1) })
            case .dictionary(let pairs):
                var entries: [SwiftAppDictionaryKey: SwiftAppValue] = [:]
                for pair in pairs {
                    let key: SwiftAppDictionaryKey
                    switch try pair.key.restore(program: program, depth: depth + 1) {
                    case .string(let value): key = .string(value)
                    case .int(let value): key = .int(value)
                    case .bool(let value): key = .bool(value)
                    default: throw SwiftAppRuntimeError("Persistent dictionary keys must be String, Int or Bool")
                    }
                    guard entries[key] == nil else { throw SwiftAppRuntimeError("Persistent dictionary has duplicate keys") }
                    entries[key] = try pair.value.restore(program: program, depth: depth + 1)
                }
                return .dictionary(entries)
            case .record(let name, let fields):
                let keys = try Self.admitRecord(name, fields: Set(fields.keys), program: program)
                return .record(SwiftAppRecord(typeName: name, keys: keys, fields: try fields.mapValues { try $0.restore(program: program, depth: depth + 1) }))
            }
        }

        @MainActor @discardableResult
        private static func admitRecord(_ name: String, fields: Set<String>, program: SwiftAppProgramSyntax) throws -> [String] {
            guard let declaration = program.types[name], declaration.kind == .structure,
                  !declaration.isView, !declaration.isApp,
                  fields == Set(declaration.stored.filter { !$0.isStatic }.map(\.name)) else {
                throw SwiftAppRuntimeError("Persistent struct '\(name)' does not match the current app source")
            }
            return declaration.stored.filter { !$0.isStatic }.map(\.name)
        }
    }
}
