import SwiftUI
import XCTest
@testable import TronMobile

/// Tests for the SkillBadges view — exercises the provenance matrix:
///   source ∈ {global, project}  ×  service ∈ {tron, claude, unknown}
///
/// Note: SkillBadges renders SwiftUI Views; we test the `serviceTag` derivation
/// and the behavior of `Skill.serviceTag` (the source of truth for which
/// badges render), not the pixel output. UI snapshot testing is out of scope.
final class SkillBadgesTests: XCTestCase {

    // MARK: - Helpers

    private func makeSkill(source: SkillSource, service: String) -> Skill {
        Skill(
            name: "test",
            displayName: "Test",
            description: "desc",
            source: source,
            tags: nil,
            service: service
        )
    }

    // MARK: - Service tag derivation

    func testServiceTagTron() {
        let skill = makeSkill(source: .global, service: "tron")
        XCTAssertEqual(skill.serviceTag, .tron)
    }

    func testServiceTagClaude() {
        let skill = makeSkill(source: .global, service: "claude")
        XCTAssertEqual(skill.serviceTag, .claude)
    }

    /// Forward-compat: a service the server knows but the client doesn't.
    func testServiceTagUnknownForFutureService() {
        let skill = makeSkill(source: .global, service: "codex")
        XCTAssertEqual(skill.serviceTag, .unknown)
    }

    func testServiceTagUnknownForEmptyString() {
        let skill = makeSkill(source: .global, service: "")
        XCTAssertEqual(skill.serviceTag, .unknown)
    }

    // MARK: - Provenance matrix (source × service)

    func testTronGlobalHasNoExtraBadges() {
        let skill = makeSkill(source: .global, service: "tron")
        XCTAssertEqual(skill.source, .global)
        XCTAssertEqual(skill.serviceTag, .tron)
        // Rendered: no project badge, no claude badge — the default/unbadged case.
    }

    func testClaudeGlobalShowsClaudeBadge() {
        let skill = makeSkill(source: .global, service: "claude")
        XCTAssertEqual(skill.source, .global)
        XCTAssertEqual(skill.serviceTag, .claude)
        // Rendered: claude badge only.
    }

    func testTronProjectShowsProjectBadge() {
        let skill = makeSkill(source: .project, service: "tron")
        XCTAssertEqual(skill.source, .project)
        XCTAssertEqual(skill.serviceTag, .tron)
        // Rendered: project badge only.
    }

    func testClaudeProjectShowsBothBadges() {
        let skill = makeSkill(source: .project, service: "claude")
        XCTAssertEqual(skill.source, .project)
        XCTAssertEqual(skill.serviceTag, .claude)
        // Rendered: project badge + claude badge.
    }

    // MARK: - Default init behavior

    func testSkillInitDefaultsServiceToTron() {
        // The default arg on Skill.init is a convenience for in-app fixtures
        // and previews. Server-decoded skills always carry an explicit service
        // (tested in SkillStoreTests.testSkillDecodesServiceField).
        let skill = Skill(
            name: "x",
            displayName: "X",
            description: "",
            source: .global,
            tags: nil
        )
        XCTAssertEqual(skill.service, "tron")
        XCTAssertEqual(skill.serviceTag, .tron)
    }

    // MARK: - SkillBadges constructs without crashing across the matrix

    func testSkillBadgesConstructsInAllStyles() {
        for svc in ["tron", "claude", "codex"] {
            for src in [SkillSource.global, .project] {
                for style in [SkillBadges.Style.capsule, .icon] {
                    let view = SkillBadges(
                        skill: makeSkill(source: src, service: svc),
                        style: style
                    )
                    // Just verify the view constructs — SwiftUI's rendering is
                    // not our unit to test, but the constructor must never
                    // trap on any source/service/style combination.
                    _ = view.body
                }
            }
        }
    }
}
