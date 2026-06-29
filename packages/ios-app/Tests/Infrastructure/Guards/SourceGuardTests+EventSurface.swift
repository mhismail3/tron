import Testing
import Foundation
@testable import TronMobile

extension SourceGuardTests {

    @Test("iOS event plugins cover Rust session stream event types")
    func testIOSPluginsCoverRustSessionStreamEventTypes() throws {
        let repoRoot = iosAppRoot()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let streamRoot = repoRoot
            .appendingPathComponent("packages/agent/src/transport/runtime/streams")

        let serverTypes = try rustSessionStreamEventTypes(in: streamRoot)
            .filter { $0 != "events.session" }

        EventRegistry.shared.clearForTesting()
        EventRegistry.shared.registerAll()
        let registeredTypes = Set(EventRegistry.shared.registeredTypes)
        let missing = serverTypes.subtracting(registeredTypes).sorted()

        #expect(
            missing.isEmpty,
            "Rust session-stream event types must have iOS plugins or become explicitly ignored by design: \(missing)"
        )
    }

    private func rustSessionStreamEventTypes(in root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var eventTypes = Set<String>()
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            guard url.pathExtension == "rs", !url.lastPathComponent.hasSuffix("tests.rs") else {
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            eventTypes.formUnion(quotedDottedStrings(in: source))
        }
        return eventTypes
    }

    private func quotedDottedStrings(in source: String) -> Set<String> {
        let pattern = #""([A-Za-z0-9_]+\.[A-Za-z0-9_.]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[capture])
        })
    }
}
