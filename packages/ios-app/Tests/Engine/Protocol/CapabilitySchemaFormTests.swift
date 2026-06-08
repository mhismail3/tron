import Foundation
import Testing
@testable import TronMobile

@Suite("Capability schema form model")
struct CapabilitySchemaFormTests {
    @Test("builds object fields with validation metadata")
    func buildsObjectFields() {
        let schema = AnyCodable([
            "type": "object",
            "required": ["path", "mode"],
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Filesystem path to read"
                ],
                "mode": [
                    "type": "string",
                    "enum": ["head", "tail"]
                ],
                "limit": [
                    "type": ["integer", "null"],
                    "default": 100
                ]
            ]
        ])

        let model = CapabilitySchemaFormModel.build(from: schema)

        #expect(model.unsupportedPaths.isEmpty)
        #expect(model.fields.count == 3)
        #expect(model.fields.first { $0.title == "path" }?.required == true)
        #expect(model.fields.first { $0.title == "path" }?.uiHint == "path")
        #expect(model.fields.first { $0.title == "mode" }?.kind == .enumeration(["head", "tail"]))
        #expect(model.fields.first { $0.title == "limit" }?.kind == .nullable(.integer))
    }

    @Test("records unsupported schema field paths")
    func recordsUnsupportedFields() {
        let schema = AnyCodable([
            "type": "object",
            "properties": [
                "callback": ["type": "function"]
            ]
        ])

        let model = CapabilitySchemaFormModel.build(from: schema)

        #expect(model.unsupportedPaths == ["payload.callback"])
    }
}
