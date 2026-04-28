import Foundation
import Testing
@testable import TronMac

@Suite("ManagedSkillInstaller")
struct ManagedSkillInstallerTests {
    @Test("sync copies managed skills and updates existing managed content")
    func syncUpdatesManagedSkill() throws {
        let tmp = try temporaryDirectory()
        let source = tmp.appendingPathComponent("bundle/Skills", isDirectory: true)
        let destination = tmp.appendingPathComponent("home/.tron/skills", isDirectory: true)
        try writeSkill(named: "plan", text: "new", in: source, managed: true)
        try writeSkill(named: "plan", text: "old", in: destination, managed: true)

        let summary = try ManagedSkillInstaller.sync(from: source, to: destination)

        #expect(summary == ManagedSkillSyncSummary(synced: 1, skippedUserOwned: 0, removedStale: 0))
        let copied = try String(contentsOf: destination.appendingPathComponent("plan/SKILL.md"), encoding: .utf8)
        #expect(copied == "new")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plan/.managed").path))
    }

    @Test("sync preserves user-owned collisions")
    func syncPreservesUserOwnedCollision() throws {
        let tmp = try temporaryDirectory()
        let source = tmp.appendingPathComponent("bundle/Skills", isDirectory: true)
        let destination = tmp.appendingPathComponent("home/.tron/skills", isDirectory: true)
        try writeSkill(named: "custom", text: "bundled", in: source, managed: true)
        try writeSkill(named: "custom", text: "user", in: destination, managed: false)

        let summary = try ManagedSkillInstaller.sync(from: source, to: destination)

        #expect(summary == ManagedSkillSyncSummary(synced: 0, skippedUserOwned: 1, removedStale: 0))
        let preserved = try String(contentsOf: destination.appendingPathComponent("custom/SKILL.md"), encoding: .utf8)
        #expect(preserved == "user")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("custom/.managed").path))
    }

    @Test("sync removes stale managed skills but keeps stale user-owned skills")
    func syncRemovesOnlyStaleManagedSkills() throws {
        let tmp = try temporaryDirectory()
        let source = tmp.appendingPathComponent("bundle/Skills", isDirectory: true)
        let destination = tmp.appendingPathComponent("home/.tron/skills", isDirectory: true)
        try writeSkill(named: "active", text: "active", in: source, managed: true)
        try writeSkill(named: "stale-managed", text: "old", in: destination, managed: true)
        try writeSkill(named: "stale-user", text: "user", in: destination, managed: false)

        let summary = try ManagedSkillInstaller.sync(from: source, to: destination)

        #expect(summary == ManagedSkillSyncSummary(synced: 1, skippedUserOwned: 0, removedStale: 1))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale-managed").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale-user/SKILL.md").path))
    }

    @Test("source skill without managed sentinel fails loudly")
    func sourceSkillWithoutManagedSentinelFails() throws {
        let tmp = try temporaryDirectory()
        let source = tmp.appendingPathComponent("bundle/Skills", isDirectory: true)
        let destination = tmp.appendingPathComponent("home/.tron/skills", isDirectory: true)
        try writeSkill(named: "broken", text: "oops", in: source, managed: false)

        do {
            _ = try ManagedSkillInstaller.sync(from: source, to: destination)
            Issue.record("expected missing .managed sentinel to fail")
        } catch ManagedSkillInstaller.Failure.sourceSkillMissingManagedSentinel(let name) {
            #expect(name == "broken")
        }
    }

    @Test("empty bundled skills directory fails loudly")
    func emptySourceFails() throws {
        let tmp = try temporaryDirectory()
        let source = tmp.appendingPathComponent("bundle/Skills", isDirectory: true)
        let destination = tmp.appendingPathComponent("home/.tron/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        do {
            _ = try ManagedSkillInstaller.sync(from: source, to: destination)
            Issue.record("expected empty managed skills bundle to fail")
        } catch ManagedSkillInstaller.Failure.missingManagedSkills(let url) {
            #expect(url == source)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-managed-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(named name: String, text: String, in root: URL, managed: Bool) throws {
        let skill = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        if managed {
            try Data().write(to: skill.appendingPathComponent(".managed"))
        }
    }
}
