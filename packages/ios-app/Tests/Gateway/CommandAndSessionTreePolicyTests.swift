import Testing
@testable import TronMobile

@Suite("Command and session-tree admission")
struct CommandAndSessionTreePolicyTests {
    private func command(
        _ name: String,
        source: CommandInfo.Source = .prompt,
        description: String? = nil,
        argumentHint: String? = nil,
        sourcePath: String? = nil
    ) -> CommandInfo {
        CommandInfo(
            name: name,
            description: description,
            argumentHint: argumentHint,
            source: source,
            sourcePath: sourcePath
        )
    }

    private func node(
        _ id: String,
        parentID: String? = nil,
        timestamp: String = "2025-01-01T00:00:00.000Z",
        preview: String = "Preview",
        depth: Int = 0,
        childCount: Int = 0
    ) -> SessionTreeNode {
        SessionTreeNode(
            id: id,
            parentId: parentID,
            timestamp: timestamp,
            kind: "message",
            label: nil,
            preview: preview,
            role: .user,
            depth: depth,
            childCount: childCount,
            isCurrentPath: true
        )
    }

    @Test("command admission preserves unique bounded order")
    func commandAdmissionPreservesOrder() throws {
        let catalog = [command("zeta", source: .skill), command("alpha", source: .extension)]
        #expect(try CommandCatalogPolicy.admit(catalog) == catalog)
    }

    @Test("command admission rejects malformed catalogs atomically")
    func commandAdmissionRejectsMalformedCatalogs() {
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit([self.command("same"), self.command("same")])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit([self.command("")])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit([self.command("two words")])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit([
                self.command(String(repeating: "🙂", count: 129))
            ])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit([
                self.command("valid", sourcePath: String(repeating: "x", count: CommandCatalogPolicy.maximumStringBytes + 1))
            ])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit((0...CommandCatalogPolicy.maximumCommands).map {
                self.command("command-\($0)")
            })
        }
        #expect(throws: GatewayFailure.self) {
            _ = try CommandCatalogPolicy.admit((0..<100).map {
                self.command("command-\($0)", description: String(repeating: "x", count: 8_000))
            })
        }
    }

    @Test("tree admission accepts a bounded newest subset with omitted parents")
    func treeAdmissionAllowsOmittedParents() throws {
        let tree = [node("newer", parentID: "older-omitted", depth: 12, childCount: 1)]
        #expect(try SessionTreePolicy.admit(tree) == tree)
    }

    @Test("tree admission rejects duplicate, malformed, and oversized responses")
    func treeAdmissionRejectsMalformedResponses() {
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit([self.node("same"), self.node("same")])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit([self.node("bad-time", timestamp: "not-a-timestamp")])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit([self.node("negative", depth: -1)])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit([self.node("negative-child", childCount: -1)])
        }
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit((0...SessionTreePolicy.maximumNodes).map { self.node("node-\($0)") })
        }
        #expect(throws: GatewayFailure.self) {
            _ = try SessionTreePolicy.admit((0..<100).map {
                self.node("node-\($0)", preview: String(repeating: "x", count: 8_000))
            })
        }
    }
}
