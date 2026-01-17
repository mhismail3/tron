import XCTest
@testable import TronMobile

@MainActor
final class PlanModeStateTests: XCTestCase {

    func testInitialState() {
        let state = PlanModeState()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.skillName)
    }

    func testEnterPlanMode() {
        let state = PlanModeState()

        state.enter(skillName: "my-skill")

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.skillName, "my-skill")
    }

    func testExitPlanMode() {
        let state = PlanModeState()
        state.enter(skillName: "my-skill")

        state.exit()

        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.skillName)
    }

    func testExitReturnsSkillName() {
        let state = PlanModeState()
        state.enter(skillName: "test-skill")

        let skillName = state.exit()

        XCTAssertEqual(skillName, "test-skill")
        XCTAssertFalse(state.isActive)
    }

    func testExitWhenNotActive() {
        let state = PlanModeState()

        let skillName = state.exit()

        XCTAssertNil(skillName)
        XCTAssertFalse(state.isActive)
    }

    func testMultipleEnterCalls() {
        let state = PlanModeState()

        state.enter(skillName: "skill-1")
        XCTAssertEqual(state.skillName, "skill-1")

        state.enter(skillName: "skill-2")
        XCTAssertEqual(state.skillName, "skill-2")
        XCTAssertTrue(state.isActive)
    }
}
