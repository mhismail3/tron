import Testing
@testable import TronMobileCore
@testable import TronMobile

@Suite("Session tool picker exposure")
struct SessionToolPickerTests {
    @Test("tools are grouped by namespace data and hidden exposure cannot be selected")
    func exposureAndActiveTools() {
        let context: JSONValue = .object([
            "availableTools": .array([
                .object(["name": .string("read"), "namespace": .string("filesystem"), "exposure": .string("direct")]),
                .object(["name": .string("secret"), "namespace": .string("private"), "exposure": .string("hidden")]),
                .object(["name": .string("mcp__calendar__events"), "namespace": .string("calendar"), "exposure": .string("codemode")]),
            ]),
            "activeTools": .array([.string("read"), .string("mcp__calendar__events")]),
        ])
        let tools = SessionToolPickerProjection.tools(from: context)
        #expect(tools.map(\.namespace) == ["calendar", "filesystem", "private"])
        #expect(tools.first(where: { $0.name == "secret" })?.selectable == false)
        #expect(SessionToolPickerProjection.activeNames(from: context) == ["read", "mcp__calendar__events"])
    }
}
