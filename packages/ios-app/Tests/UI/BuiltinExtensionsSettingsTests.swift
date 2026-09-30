import Testing
import TronMobileCore
@testable import TronMobile

@Suite("Built-in extension settings scope")
struct BuiltinExtensionsSettingsTests {
    @Test("global and project controls read only their own documents")
    func selectsDocumentForEditingScope() {
        let root: JSONValue = .object(["documents": .object([
            "global": .object([
                "defaultTools": .array([.string("global-tool")]),
                "codemode": .object(["mode": .string("only")]),
            ]),
            "project": .object([
                "defaultTools": .array([.string("project-tool")]),
                "codemode": .object(["mode": .string("on")]),
            ]),
        ])])

        let global = BuiltinExtensionsSettingsPolicy.document(from: root, target: .global)
        let project = BuiltinExtensionsSettingsPolicy.document(from: root, target: .project(cwd: "/project"))
        #expect(global?["defaultTools"]?.arrayValue?.compactMap(\.stringValue) == ["global-tool"])
        #expect(project?["defaultTools"]?.arrayValue?.compactMap(\.stringValue) == ["project-tool"])
        #expect(global?["codemode"]?.objectValue?["mode"]?.stringValue == "only")
        #expect(project?["codemode"]?.objectValue?["mode"]?.stringValue == "on")
    }

    @Test("loading a mode value never admits a settings write")
    func suppressesReadbackWrite() {
        #expect(!BuiltinExtensionsSettingsPolicy.shouldPersistModeChange(value: "only", loadedValue: "only", loading: false))
        #expect(!BuiltinExtensionsSettingsPolicy.shouldPersistModeChange(value: "on", loadedValue: "only", loading: true))
        #expect(BuiltinExtensionsSettingsPolicy.shouldPersistModeChange(value: "on", loadedValue: "only", loading: false))
    }
}
