import Testing
import Foundation
@testable import TronMobile

/// Tests for the iOS MemorySection wire format + decode path.
/// The view itself is rendered via SwiftUI previews; the tests here
/// focus on what's easily unit-testable: the UserMemorySnapshot decoder
/// and the current DetailedContextSnapshotResult wire shape.
@Suite("UserMemorySnapshot")
struct UserMemorySnapshotTests {

    // MARK: - Decoding

    @Test("Decodes bootstrapped state with populated rules")
    func testDecode_bootstrappedWithRules() throws {
        let json = """
        {
            "content": "# Personal\\n- Name: Alice\\n",
            "ruleFiles": [
                {"name": "user-preferences.md", "description": "Work style"},
                {"name": "apple-cert.md"}
            ],
            "bootstrapped": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(UserMemorySnapshot.self, from: data)
        #expect(decoded.content.contains("# Personal"))
        #expect(decoded.bootstrapped == true)
        #expect(decoded.ruleFiles.count == 2)
        #expect(decoded.ruleFiles[0].name == "user-preferences.md")
        #expect(decoded.ruleFiles[0].description == "Work style")
        #expect(decoded.ruleFiles[1].name == "apple-cert.md")
        #expect(decoded.ruleFiles[1].description == nil)
    }

    @Test("Decodes unbootstrapped state with empty rules")
    func testDecode_unbootstrappedEmptyRules() throws {
        let json = """
        {
            "content": "# MEMORY.md is empty\\n\\nCreate it when you learn user info.",
            "ruleFiles": [],
            "bootstrapped": false
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(UserMemorySnapshot.self, from: data)
        #expect(decoded.bootstrapped == false)
        #expect(decoded.ruleFiles.isEmpty)
        #expect(decoded.content.contains("MEMORY.md is empty"))
    }

    @Test("Missing description field decodes to nil")
    func testDecode_missingDescription() throws {
        let json = """
        {"name": "foo.md"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(UserMemoryRuleFile.self, from: data)
        #expect(decoded.description == nil)
    }

    // MARK: - Identifiable

    @Test("UserMemoryRuleFile.id == name")
    func testIdentifiableUsesName() {
        let rule = UserMemoryRuleFile(name: "foo.md", description: nil)
        #expect(rule.id == "foo.md")
    }

    // MARK: - Equatable

    @Test("UserMemorySnapshot Equatable by content + rules + bootstrapped")
    func testEquality() {
        let a = UserMemorySnapshot(
            content: "x",
            ruleFiles: [UserMemoryRuleFile(name: "r.md", description: "d")],
            bootstrapped: true
        )
        let b = UserMemorySnapshot(
            content: "x",
            ruleFiles: [UserMemoryRuleFile(name: "r.md", description: "d")],
            bootstrapped: true
        )
        let c = UserMemorySnapshot(
            content: "x",
            ruleFiles: [UserMemoryRuleFile(name: "r.md", description: "d")],
            bootstrapped: false
        )
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Wire compat with DetailedContextSnapshotResult

    @Test("DetailedContextSnapshotResult decodes with memory populated")
    func testDecode_detailedSnapshot_memoryPopulated() throws {
        let json = """
        {
            "currentTokens": 1000,
            "contextLimit": 200000,
            "usagePercent": 0.5,
            "thresholdLevel": "safe",
            "breakdown": {
                "systemPrompt": 500,
                "tools": 200,
                "rules": 0,
                "memory": 50,
                "skillIndex": 0,
                "skillContext": 0,
                "skillRemoval": 0,
                "jobResults": 0,
                "environment": 0,
                "messages": 0,
                "providerAdjustment": 250
            },
            "messages": [],
            "systemPromptContent": "You are Tron.",
            "toolsContent": [],
            "addedSkills": [],
            "memory": {
                "content": "# Me",
                "ruleFiles": [],
                "bootstrapped": true
            }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DetailedContextSnapshotResult.self, from: data)
        #expect(decoded.memory != nil)
        #expect(decoded.memory?.bootstrapped == true)
        #expect(decoded.memory?.content == "# Me")
        #expect(decoded.breakdown.providerAdjustment == 250)
    }

    @Test("DetailedContextSnapshotResult tolerates memory == null")
    func testDecode_detailedSnapshot_memoryNull() throws {
        // Current local-model snapshots emit memory: null when no server-owned
        // memory content is present. iOS must still decode without error.
        let json = """
        {
            "currentTokens": 0,
            "contextLimit": 100,
            "usagePercent": 0,
            "thresholdLevel": "safe",
            "breakdown": {
                "systemPrompt": 0, "tools": 0, "rules": 0, "memory": 0,
                "skillIndex": 0, "skillContext": 0, "skillRemoval": 0,
                "jobResults": 0, "environment": 0, "messages": 0
            },
            "messages": [],
            "systemPromptContent": "",
            "toolsContent": [],
            "addedSkills": [],
            "memory": null
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DetailedContextSnapshotResult.self, from: data)
        #expect(decoded.memory == nil)
    }
}
