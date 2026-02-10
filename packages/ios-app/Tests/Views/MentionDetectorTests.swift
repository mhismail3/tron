import XCTest
@testable import TronMobile

final class MentionDetectorTests: XCTestCase {

    private let skillDetector = MentionDetector.skill
    private let spellDetector = MentionDetector.spell

    // MARK: - Helper

    private func makeSkill(_ name: String, tags: [String]? = nil) -> Skill {
        Skill(name: name, displayName: name.capitalized, description: "Description for \(name)", source: .global, tags: tags)
    }

    // MARK: - Basic Detection (@)

    func testDetectMention_atTrigger_returnsQuery() {
        XCTAssertEqual(skillDetector.detectMention(in: "hello @foo"), "foo")
    }

    func testDetectMention_percentTrigger_returnsQuery() {
        XCTAssertEqual(spellDetector.detectMention(in: "hello %foo"), "foo")
    }

    func testDetectMention_atStartOfString() {
        XCTAssertEqual(skillDetector.detectMention(in: "@test"), "test")
    }

    func testDetectMention_emptyQuery() {
        XCTAssertEqual(skillDetector.detectMention(in: "hello @"), "")
    }

    func testDetectMention_noTrigger_returnsNil() {
        XCTAssertNil(skillDetector.detectMention(in: "hello"))
    }

    func testDetectMention_triggerInsideWord_returnsNil() {
        XCTAssertNil(skillDetector.detectMention(in: "email@test"))
    }

    // MARK: - Whitespace / Boundary Rules

    func testDetectMention_afterNewline() {
        XCTAssertEqual(skillDetector.detectMention(in: "line1\n@foo"), "foo")
    }

    func testDetectMention_afterTab() {
        XCTAssertEqual(skillDetector.detectMention(in: "text\t@foo"), "foo")
    }

    func testDetectMention_afterMultipleSpaces() {
        XCTAssertEqual(skillDetector.detectMention(in: "text  @foo"), "foo")
    }

    func testDetectMention_triggerFollowedBySpace_returnsNil() {
        XCTAssertNil(skillDetector.detectMention(in: "@foo bar"))
    }

    func testDetectMention_triggerFollowedByNewline_returnsNil() {
        XCTAssertNil(skillDetector.detectMention(in: "@foo\nbar"))
    }

    // MARK: - Backtick Escaping

    func testDetectMention_insideSingleBackticks_returnsNil() {
        XCTAssertNil(skillDetector.detectMention(in: "`code @foo`"))
    }

    func testDetectMention_insideTripleBackticks_returnsNil() {
        // Odd number of backticks = inside code
        XCTAssertNil(skillDetector.detectMention(in: "```code @foo"))
    }

    func testDetectMention_afterClosedBackticks_returnsMention() {
        XCTAssertEqual(skillDetector.detectMention(in: "`code` @foo"), "foo")
    }

    func testDetectMention_emptyBacktickPair_thenMention() {
        XCTAssertEqual(skillDetector.detectMention(in: "`` @foo"), "foo")
    }

    // MARK: - Completed Mention Detection

    func testDetectCompletedMention_matchesExactSkillName() {
        let skills = [makeSkill("typescript-rules")]
        let result = skillDetector.detectCompletedMention(in: "@typescript-rules ", skills: skills, alreadySelected: [])
        XCTAssertEqual(result?.name, "typescript-rules")
    }

    func testDetectCompletedMention_caseInsensitive() {
        let skills = [makeSkill("typescript-rules")]
        let result = skillDetector.detectCompletedMention(in: "@TypeScript-Rules ", skills: skills, alreadySelected: [])
        XCTAssertEqual(result?.name, "typescript-rules")
    }

    func testDetectCompletedMention_alreadySelected_returnsNil() {
        let skill = makeSkill("typescript-rules")
        let result = skillDetector.detectCompletedMention(in: "@typescript-rules ", skills: [skill], alreadySelected: [skill])
        XCTAssertNil(result)
    }

    func testDetectCompletedMention_noMatch_returnsNil() {
        let skills = [makeSkill("typescript-rules")]
        let result = skillDetector.detectCompletedMention(in: "@nonexistent ", skills: skills, alreadySelected: [])
        XCTAssertNil(result)
    }

    func testDetectCompletedMention_atEndOfString_matchesSkill() {
        let skills = [makeSkill("typescript-rules")]
        let result = skillDetector.detectCompletedMention(in: "@typescript-rules", skills: skills, alreadySelected: [])
        // End of string counts as word boundary — regex uses (?:\s|$)
        XCTAssertEqual(result?.name, "typescript-rules")
    }

    func testDetectCompletedMention_insideBackticks_returnsNil() {
        let skills = [makeSkill("foo")]
        let result = skillDetector.detectCompletedMention(in: "`@foo `", skills: skills, alreadySelected: [])
        XCTAssertNil(result)
    }

    func testDetectCompletedMention_midWord_returnsNil() {
        let skills = [makeSkill("bar")]
        let result = skillDetector.detectCompletedMention(in: "foo@bar ", skills: skills, alreadySelected: [])
        XCTAssertNil(result)
    }

    // MARK: - Spell Detection (%trigger)

    func testDetectCompletedMention_percentTrigger() {
        let skills = [makeSkill("typescript-rules")]
        let result = spellDetector.detectCompletedMention(in: "%typescript-rules ", skills: skills, alreadySelected: [])
        XCTAssertEqual(result?.name, "typescript-rules")
    }

    // MARK: - Filtering

    func testFilterSkills_emptyQuery_returnsAll() {
        let skills = [makeSkill("a"), makeSkill("b"), makeSkill("c")]
        let result = MentionDetector.filterSkills(skills, query: "")
        XCTAssertEqual(result.count, 3)
    }

    func testFilterSkills_matchesName() {
        let skills = [makeSkill("typescript-rules"), makeSkill("api-design")]
        let result = MentionDetector.filterSkills(skills, query: "type")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "typescript-rules")
    }

    func testFilterSkills_matchesDescription() {
        let skills = [Skill(name: "foo", displayName: "Foo", description: "Handles TypeScript validation", source: .global, tags: nil)]
        let result = MentionDetector.filterSkills(skills, query: "typescript")
        XCTAssertEqual(result.count, 1)
    }

    func testFilterSkills_matchesTags() {
        let skills = [makeSkill("foo", tags: ["coding", "typescript"])]
        let result = MentionDetector.filterSkills(skills, query: "typescript")
        XCTAssertEqual(result.count, 1)
    }

    func testFilterSkills_noMatch_returnsEmpty() {
        let skills = [makeSkill("typescript-rules"), makeSkill("api-design")]
        let result = MentionDetector.filterSkills(skills, query: "zzz")
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterSkills_prefixMatchesSortedFirst() {
        let skills = [makeSkill("api-design"), makeSkill("typescript-api")]
        let result = MentionDetector.filterSkills(skills, query: "api")
        XCTAssertEqual(result.first?.name, "api-design", "Prefix match should sort first")
    }

    func testFilterSkills_shorterNamesSortedFirst_whenEqualPrefix() {
        let skills = [makeSkill("api-design-extended"), makeSkill("api-design")]
        let result = MentionDetector.filterSkills(skills, query: "api")
        XCTAssertEqual(result.first?.name, "api-design", "Shorter name should sort first when both are prefix matches")
    }
}
