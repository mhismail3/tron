import Testing
@testable import TronMobile

@Suite("Structured JSON live path resolution")
struct StructuredJSONPathTests {
    @Test("nested object and array paths resolve against the supplied root")
    func resolvesNestedPath() {
        let root: JSONValue = .object([
            "result": .object([
                "items": .array([
                    .object(["status": .string("first")]),
                    .object(["status": .string("second")]),
                ]),
            ]),
        ])
        let path: [StructuredJSONPathComponent] = [
            .key("result"), .key("items"), .index(1), .key("status"),
        ]
        #expect(StructuredJSONPath.resolve(root, components: path) == .string("second"))
        #expect(StructuredJSONPath.display(path) == "$.result.items[1].status")
    }

    @Test("arbitrary keys have unambiguous escaped display paths")
    func escapedDisplayPaths() {
        #expect(StructuredJSONPath.display([.key("a.b")]) == #"$["a.b"]"#)
        #expect(StructuredJSONPath.display([.key("a"), .key("b")]) == "$.a.b")
        #expect(StructuredJSONPath.display([.key("items[0]")]) == #"$["items[0]"]"#)
        #expect(StructuredJSONPath.display([.key("")]) == #"$[""]"#)
        #expect(StructuredJSONPath.display([.key("quote\"slash\\line\n")]) == #"$["quote\"slash\\line\n"]"#)
        #expect(StructuredJSONPath.display([.key("café")]) == "$.café")
        #expect(StructuredJSONPath.display([.key("1st")]) == #"$["1st"]"#)
    }

    @Test("structural paths remain distinct when display punctuation appears in keys")
    func structuralIdentityDoesNotCollide() {
        let dotted: [StructuredJSONPathComponent] = [.key("a.b")]
        let nested: [StructuredJSONPathComponent] = [.key("a"), .key("b")]
        #expect(dotted != nested)
        #expect(StructuredJSONPath.display(dotted) != StructuredJSONPath.display(nested))
    }

    @Test("the same selection path resolves the newest live root value")
    func newestRootWins() {
        let path: [StructuredJSONPathComponent] = [.key("result"), .key("status")]
        let initial: JSONValue = .object([
            "result": .object(["status": .string("running")]),
        ])
        let updated: JSONValue = .object([
            "result": .object(["status": .string("completed")]),
        ])
        #expect(StructuredJSONPath.resolve(initial, components: path) == .string("running"))
        #expect(StructuredJSONPath.resolve(updated, components: path) == .string("completed"))
    }

    @Test("removed or type-changed paths fail closed")
    func missingPath() {
        let path: [StructuredJSONPathComponent] = [.key("items"), .index(2)]
        #expect(StructuredJSONPath.resolve(.object(["items": .array([])]), components: path) == nil)
        #expect(StructuredJSONPath.resolve(.object(["items": .string("changed")]), components: path) == nil)
    }
}
