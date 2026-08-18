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

    @Test("large array fields preserve exact index identity without eager tuple projection")
    func largeArrayFieldCollection() {
        let values = (0 ..< 10_000).map { JSONValue.string("/tmp/item-\($0).txt") }
        let fields = StructuredJSONFields(array: values)

        #expect(fields.count == 10_000)
        #expect(fields[0].id == .index(0))
        #expect(fields[0].label == "item-0.txt")
        #expect(fields[9_999].id == .index(9_999))
        #expect(fields[9_999].label == "item-9999.txt")
        #expect(fields[9_999].value == values[9_999])
    }

    @Test("object fields retain preferred ordering, labels, and structural key identity")
    func objectFieldCollection() {
        let fields = StructuredJSONFields(object: [
            "z_value": .number(3),
            "status": .string("ready"),
            "answer": .bool(true),
            "camelCase": .null,
        ])

        #expect(fields.map(\.component) == [
            .key("status"), .key("answer"), .key("camelCase"), .key("z_value"),
        ])
        #expect(fields.map(\.label) == ["Status", "Answer", "Camel Case", "Z Value"])
    }

    @Test("removed or type-changed paths fail closed")
    func missingPath() {
        let path: [StructuredJSONPathComponent] = [.key("items"), .index(2)]
        #expect(StructuredJSONPath.resolve(.object(["items": .array([])]), components: path) == nil)
        #expect(StructuredJSONPath.resolve(.object(["items": .string("changed")]), components: path) == nil)
    }
}
