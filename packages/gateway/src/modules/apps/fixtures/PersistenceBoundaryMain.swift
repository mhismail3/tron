#if SWIFT_APP_PERSISTENCE_BOUNDARY
import Foundation

/// Compiled with the real engine by the Gateway boundary journey. No model,
/// interpreter or storage is replaced: each invocation is a fresh native
/// process, with the Gateway's exact source and stored JSON as its input.
@main
struct PersistenceBoundaryMain {
    struct Input: Decodable {
        let source: String
        let entries: [String: String]
        let installed: Bool
        let actions: [String]
    }

    struct Write: Encodable { let key: String; let json: String }
    struct Observation: Encodable { let action: String; let succeeded: Bool; let report: String; let error: String? }
    struct Output: Encodable { let batches: [[Write]]; let observations: [Observation]; let error: String? }

    @MainActor
    static func main() throws {
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        var batches: [[Write]] = []
        var observations: [Observation] = []
        do {
            let entries = try input.entries.mapValues { text in
                guard let data = Data(base64Encoded: text) else { throw SwiftAppRuntimeError("Invalid fixture input") }
                return data
            }
            let persistence = input.installed ? SwiftAppPersistence(entries: entries) { writes in
                batches.append(writes.map { Write(key: $0.key, json: $0.value.base64EncodedString()) })
            } : nil
            let runtime = try SwiftAppRuntime(source: input.source, linkPolicy: SwiftAppLinkPolicy(host: nil), persistence: persistence)
            guard let root = runtime.rootDeclaration else { throw SwiftAppRuntimeError("No fixture root") }
            let state = try runtime.initialState(for: root, arguments: [])
            let node = SwiftAppViewNode(name: root.name, arguments: [], declaration: root)
            let instance = SwiftAppViewInstance(declaration: root, properties: try runtime.properties(for: node), state: state, environmentObjects: [:], dismiss: nil)
            let scope = SwiftAppScope(parent: runtime.globals, selfReference: .view(instance))
            func report() throws -> String { try runtime.entered { try runtime.lookup("report", in: scope).display } }
            observations.append(Observation(action: "opened", succeeded: true, report: try report(), error: nil))
            for action in input.actions {
                let succeeded: Bool
                if action == "binding" {
                    try runtime.binding(named: "count", in: scope).set(.int(7))
                    succeeded = runtime.actionError == nil
                } else {
                    succeeded = runtime.perform(try runtime.lookup(action, in: scope))
                }
                observations.append(Observation(action: action, succeeded: succeeded, report: try report(), error: runtime.actionError))
            }
            try emit(Output(batches: batches, observations: observations, error: nil))
        } catch {
            try emit(Output(batches: batches, observations: observations, error: String(describing: error)))
        }
    }

    static func emit(_ output: Output) throws {
        FileHandle.standardOutput.write(try JSONEncoder().encode(output))
    }
}
#endif
