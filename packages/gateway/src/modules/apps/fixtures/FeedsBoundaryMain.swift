#if SWIFT_APP_FEEDS_BOUNDARY
import Foundation

/// A fresh native interpreter process consumes the real Gateway's exact feed.
@main
struct FeedsBoundaryMain {
    struct Input: Decodable {
        let source: String
        let feeds: [String: SwiftAppIOSBuildsFeed]?
        let host: String?
        let action: String?
        let userInitiated: Bool
    }
    struct Output: Encodable {
        let report: String?
        let succeeded: Bool
        let link: String?
        let error: String?
    }
    @MainActor static func main() throws {
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        do {
            let manifests = input.feeds.map { $0.values.flatMap { $0.builds.map(\.manifestURL) } }
            let runtime = try SwiftAppRuntime(source: input.source,
                linkPolicy: SwiftAppLinkPolicy(host: input.host, manifestURLs: manifests), feeds: input.feeds)
            guard let root = runtime.rootDeclaration else { throw SwiftAppRuntimeError("No fixture root") }
            let node = SwiftAppViewNode(name: root.name, arguments: [], declaration: root)
            let instance = SwiftAppViewInstance(declaration: root, properties: try runtime.properties(for: node),
                state: try runtime.initialState(for: root, arguments: []), environmentObjects: [:], dismiss: nil)
            let scope = SwiftAppScope(parent: runtime.globals, selfReference: .view(instance))
            let report = try runtime.entered { try runtime.lookup("report", in: scope).display }
            let succeeded = try input.action.map { name in runtime.perform(try runtime.lookup(name, in: scope), userInitiated: input.userInitiated) } ?? true
            try emit(Output(report: report, succeeded: succeeded, link: runtime.pendingLink?.url.absoluteString, error: runtime.actionError))
        } catch { try emit(Output(report: nil, succeeded: false, link: nil, error: String(describing: error))) }
    }
    static func emit(_ output: Output) throws { FileHandle.standardOutput.write(try JSONEncoder().encode(output)) }
}
#endif
