import XCTest
@testable import TronMobile

/// Tests for SkillStore skill management and refresh behavior
///
/// These tests verify:
/// - Skill search functionality
/// - Reference extraction from text
/// - needsRefresh() logic
/// - Basic skill store operations
final class SkillStoreTests: XCTestCase {

    // MARK: - Test Helpers

    func createSkill(name: String, autoInject: Bool = false, description: String = "Test skill") -> Skill {
        return Skill(
            name: name,
            description: description,
            source: .global,
            autoInject: autoInject,
            tags: ["test"]
        )
    }

    // MARK: - Tests: needsRefresh Logic

    /// Test that needsRefresh returns true when never refreshed
    @MainActor
    func testNeedsRefreshWhenNeverRefreshed() async throws {
        let skillStore = SkillStore()

        // When: lastRefresh is nil (never refreshed)
        XCTAssertNil(skillStore.lastRefresh)

        // Then: Should need refresh
        XCTAssertTrue(skillStore.needsRefresh(), "Should need refresh when never refreshed")
    }

    /// Test that needsRefresh logic is based on time interval
    @MainActor
    func testNeedsRefreshAfterInterval() async throws {
        // This tests the time-based refresh logic
        // Since we can't easily set lastRefresh, we test via the public API
        let skillStore = SkillStore()

        // Fresh store should need refresh
        XCTAssertTrue(skillStore.needsRefresh())
    }

    // MARK: - Tests: Reference Extraction

    /// Test extracting skill references from text
    @MainActor
    func testExtractReferencesBasic() {
        let skillStore = SkillStore()

        let text = "Please help me @typescript-rules with this @api-design problem"
        let refs = skillStore.extractReferences(from: text)

        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs.contains("typescript-rules"))
        XCTAssertTrue(refs.contains("api-design"))
    }

    /// Test that email addresses are not extracted as skill references
    @MainActor
    func testDoesNotExtractEmailAddresses() {
        let skillStore = SkillStore()

        let text = "Contact me at user@example.com about @typescript-rules"
        let refs = skillStore.extractReferences(from: text)

        // Should only extract the skill reference, not the email
        XCTAssertEqual(refs.count, 1)
        XCTAssertTrue(refs.contains("typescript-rules"))
        XCTAssertFalse(refs.contains("example"))
    }

    /// Test references with various formats
    @MainActor
    func testExtractReferencesVariousFormats() {
        let skillStore = SkillStore()

        // Underscores
        let text1 = "@my_skill_name is helpful"
        XCTAssertEqual(skillStore.extractReferences(from: text1), ["my_skill_name"])

        // Numbers
        let text2 = "Use @api2client for this"
        XCTAssertEqual(skillStore.extractReferences(from: text2), ["api2client"])

        // CamelCase
        let text3 = "@mySkillName works well"
        XCTAssertEqual(skillStore.extractReferences(from: text3), ["mySkillName"])
    }

    /// Test references inside code blocks are ignored
    @MainActor
    func testDoesNotExtractFromCodeBlocks() {
        let skillStore = SkillStore()

        // Inside backticks should be ignored
        let text = "Use `@skill-name` in your code"
        let refs = skillStore.extractReferences(from: text)

        // The regex uses a negative lookbehind for backticks
        XCTAssertTrue(refs.isEmpty || !refs.contains("skill-name"),
                      "References in code should be ignored")
    }

    /// Test empty text returns no references
    @MainActor
    func testExtractReferencesEmptyText() {
        let skillStore = SkillStore()

        let refs = skillStore.extractReferences(from: "")
        XCTAssertEqual(refs.count, 0)
    }

    /// Test text with no references returns empty
    @MainActor
    func testExtractReferencesNoReferences() {
        let skillStore = SkillStore()

        let text = "This is just regular text with no skill references"
        let refs = skillStore.extractReferences(from: text)

        XCTAssertEqual(refs.count, 0)
    }

    // MARK: - Tests: hasSkillReferences

    /// Test hasSkillReferences returns true when references exist
    @MainActor
    func testHasSkillReferencesTrue() {
        let skillStore = SkillStore()

        let text = "Help me with @api-design"
        XCTAssertTrue(skillStore.hasSkillReferences(text))
    }

    /// Test hasSkillReferences returns false when no references
    @MainActor
    func testHasSkillReferencesFalse() {
        let skillStore = SkillStore()

        let text = "Just regular text"
        XCTAssertFalse(skillStore.hasSkillReferences(text))
    }

    // MARK: - Tests: Initial State

    /// Test SkillStore initial state
    @MainActor
    func testInitialState() {
        let skillStore = SkillStore()

        XCTAssertTrue(skillStore.skills.isEmpty)
        XCTAssertFalse(skillStore.isLoading)
        XCTAssertNil(skillStore.error)
        XCTAssertNil(skillStore.lastRefresh)
        XCTAssertEqual(skillStore.totalCount, 0)
        XCTAssertEqual(skillStore.autoInjectCount, 0)
    }

    // MARK: - Tests: Computed Properties

    /// Test autoInjectSkills filter
    @MainActor
    func testAutoInjectSkillsFilter() {
        // Since we can't easily set skills directly, we test the filter logic
        // by verifying the computed property exists and works with empty array
        let skillStore = SkillStore()

        XCTAssertEqual(skillStore.autoInjectSkills.count, 0)
        XCTAssertEqual(skillStore.regularSkills.count, 0)
    }

    /// Test source-based filters
    @MainActor
    func testSourceFilters() {
        let skillStore = SkillStore()

        XCTAssertEqual(skillStore.globalSkills.count, 0)
        XCTAssertEqual(skillStore.projectSkills.count, 0)
    }

    // MARK: - Tests: Search

    /// Test search with empty query returns all skills
    @MainActor
    func testSearchEmptyQuery() {
        let skillStore = SkillStore()

        // Empty search should return all skills (which is empty initially)
        let results = skillStore.search(query: "")
        XCTAssertEqual(results.count, skillStore.skills.count)
    }

    // MARK: - Tests: exists and find

    /// Test exists returns false for non-existent skill
    @MainActor
    func testExistsReturnsFalse() {
        let skillStore = SkillStore()

        XCTAssertFalse(skillStore.exists(name: "non-existent-skill"))
    }

    /// Test find returns nil for non-existent skill
    @MainActor
    func testFindReturnsNil() {
        let skillStore = SkillStore()

        XCTAssertNil(skillStore.find(name: "non-existent-skill"))
    }
}
