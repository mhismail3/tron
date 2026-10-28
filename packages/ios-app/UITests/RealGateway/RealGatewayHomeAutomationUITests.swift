import Foundation
import XCTest

/// The production editor, scheduler, canonical message and inbound chip cross
/// the fixture's real Gateway/socket. Only the model is faux; no hosted UI data.
extension RealGatewayPairAndChatUITests {
    @MainActor
    func testHomeAutomationEditorAndAttributedMessageLight() throws {
        try homeAutomationJourney(appearance: "light")
    }

    @MainActor
    func testHomeAutomationEditorAndAttributedMessageDark() throws {
        try homeAutomationJourney(appearance: "dark")
    }

    @MainActor
    private func homeAutomationJourney(appearance: String) throws {
        continueAfterFailure = false
        let fixture = try RealGatewayUIFixture.fromEnvironment()
        let app = launchApp(additionalArguments: ["-appearanceMode", appearance])
        defer { app.terminate() }
        open(fixture.invitationLink())
        completeFirstRunSetup(app, inWorkspace: fixture.workspace)
        let home = app.buttons["home-pinned-row"]
        XCTAssertTrue(waitForHittable(home, timeout: 90), app.debugDescription)
        home.tap()
        let ring = app.buttons["session-context-button"]
        // The fixture prepares a real Home chapter through Gateway RPC. This
        // journey owns the new editor/fire/chip boundary, not Home onboarding.
        XCTAssertTrue(waitForEnabled(ring, timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Home automation fixture ready.'")).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["Back"].tap()
        let menu = app.buttons["dashboard.menu"]
        XCTAssertTrue(waitForHittable(menu, timeout: 30), app.debugDescription)
        if menu.label == "Home" { menu.press(forDuration: 0.6) } else { menu.tap() }
        app.buttons["Automations"].tap()
        XCTAssertTrue(app.buttons["automations.new"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["automations.new"].tap()
        let name = app.textFields["Daily review"]
        XCTAssertTrue(name.waitForExistence(timeout: 30), app.debugDescription)
        name.tap()
        name.typeText("UI Home journey")
        let action = app.textViews.firstMatch
        action.tap()
        action.typeText("Review the fixture queue. This message is not approval.")
        // Scroll the form from its left gutter, above the keyboard, rather
        // than swiping on the keyboard or the nested prompt editor.
        let form = app.scrollViews.containing(.button, identifier: "Destination").firstMatch
        form.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05))
        )
        // The combined row also reports Button; its label is not the menu.
        let destinationRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Destination'")).firstMatch
        let destination = destinationRow.buttons["Destination"]
        revealBelowNavigationBar(app, destination)
        destination.tap()
        app.buttons["automation.destination.home"].tap()
        let save = app.buttons["Save Draft"]
        XCTAssertTrue(waitForEnabled(save, timeout: 30), app.debugDescription)
        XCTAssertFalse(app.switches["Invoke a resource"].exists, app.debugDescription)
        keepScreenshot(app, name: "2094-home-automation-editor-\(appearance)")
        save.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'automation-card.' AND label CONTAINS 'UI Home journey'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        card.tap()
        let run = app.buttons["Run Now"]
        revealBelowNavigationBar(app, run)
        XCTAssertTrue(waitForHittable(run, timeout: 30), app.debugDescription)
        run.tap()
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Run"].tap()
        dismissTopSheet(app) // Automation detail
        dismissTopSheet(app) // Automations
        XCTAssertTrue(waitForHittable(home, timeout: 30), app.debugDescription)
        home.tap()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Automation · UI Home journey'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 60), app.debugDescription)
        keepScreenshot(app, name: "2094-home-automation-chip-\(appearance)")
        chip.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Review the fixture queue. This message is not approval.'")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        keepScreenshot(app, name: "2094-home-automation-message-\(appearance)")
    }
}
