import Testing
import Foundation
@testable import TronMobile

// MARK: - ComputerUseDetailsHelper Tests

@Suite("ComputerUseDetailsHelper")
struct ComputerUseDetailsHelperTests {

    // MARK: - Action Extraction

    @Test("Extracts action from details")
    func testActionFromDetails() {
        let details: [String: AnyCodable] = ["action": AnyCodable("click")]
        #expect(ComputerUseDetailsHelper.action(from: details) == "click")
    }

    @Test("Returns nil for missing action")
    func testActionMissing() {
        let details: [String: AnyCodable] = [:]
        #expect(ComputerUseDetailsHelper.action(from: details) == nil)
    }

    @Test("Returns nil for nil details")
    func testActionNilDetails() {
        #expect(ComputerUseDetailsHelper.action(from: nil) == nil)
    }

    // MARK: - Coordinate Extraction

    @Test("Extracts x coordinate as Double")
    func testXCoordDouble() {
        let details: [String: AnyCodable] = ["x": AnyCodable(100.5)]
        #expect(ComputerUseDetailsHelper.x(from: details) == 100.5)
    }

    @Test("Extracts x coordinate from Int")
    func testXCoordInt() {
        let details: [String: AnyCodable] = ["x": AnyCodable(200)]
        #expect(ComputerUseDetailsHelper.x(from: details) == 200.0)
    }

    @Test("Extracts y coordinate")
    func testYCoord() {
        let details: [String: AnyCodable] = ["y": AnyCodable(300)]
        #expect(ComputerUseDetailsHelper.y(from: details) == 300.0)
    }

    @Test("Returns nil for missing coordinates")
    func testMissingCoords() {
        let details: [String: AnyCodable] = ["action": AnyCodable("click")]
        #expect(ComputerUseDetailsHelper.x(from: details) == nil)
        #expect(ComputerUseDetailsHelper.y(from: details) == nil)
    }

    // MARK: - Click Count

    @Test("Extracts click count from Int")
    func testClickCountInt() {
        let details: [String: AnyCodable] = ["clicks": AnyCodable(2)]
        #expect(ComputerUseDetailsHelper.clicks(from: details) == 2)
    }

    @Test("Extracts click count from Double")
    func testClickCountDouble() {
        let details: [String: AnyCodable] = ["clicks": AnyCodable(1.0)]
        #expect(ComputerUseDetailsHelper.clicks(from: details) == 1)
    }

    // MARK: - Text Length

    @Test("Extracts text length")
    func testTextLength() {
        let details: [String: AnyCodable] = ["length": AnyCodable(42)]
        #expect(ComputerUseDetailsHelper.textLength(from: details) == 42)
    }

    // MARK: - Keys Extraction

    @Test("Extracts keys array")
    func testKeysArray() {
        let details: [String: AnyCodable] = ["keys": AnyCodable(["cmd", "c"])]
        let keys = ComputerUseDetailsHelper.keys(from: details)
        #expect(keys == ["cmd", "c"])
    }

    @Test("Returns nil for missing keys")
    func testKeysMissing() {
        let details: [String: AnyCodable] = ["action": AnyCodable("keypress")]
        #expect(ComputerUseDetailsHelper.keys(from: details) == nil)
    }

    // MARK: - Scroll Properties

    @Test("Extracts direction")
    func testDirection() {
        let details: [String: AnyCodable] = ["direction": AnyCodable("down")]
        #expect(ComputerUseDetailsHelper.direction(from: details) == "down")
    }

    @Test("Extracts amount")
    func testAmount() {
        let details: [String: AnyCodable] = ["amount": AnyCodable(200)]
        #expect(ComputerUseDetailsHelper.amount(from: details) == 200)
    }

    // MARK: - Window

    @Test("Extracts window title")
    func testWindow() {
        let details: [String: AnyCodable] = ["window": AnyCodable("Safari")]
        #expect(ComputerUseDetailsHelper.window(from: details) == "Safari")
    }

    // MARK: - Screenshot Size

    @Test("Extracts size in bytes")
    func testSizeBytes() {
        let details: [String: AnyCodable] = ["sizeBytes": AnyCodable(2048576)]
        #expect(ComputerUseDetailsHelper.sizeBytes(from: details) == 2048576)
    }

    // MARK: - Fallback

    @Test("Detects fallback mode")
    func testFallback() {
        let details: [String: AnyCodable] = ["fallback": AnyCodable(true)]
        #expect(ComputerUseDetailsHelper.isFallback(from: details) == true)
    }

    @Test("Defaults to no fallback")
    func testNoFallback() {
        let details: [String: AnyCodable] = ["action": AnyCodable("scroll")]
        #expect(ComputerUseDetailsHelper.isFallback(from: details) == false)
    }

    // MARK: - Mutating Check

    @Test("Click is mutating")
    func testClickMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("click") == true)
    }

    @Test("Type is mutating")
    func testTypeMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("type") == true)
    }

    @Test("Keypress is mutating")
    func testKeypressMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("keypress") == true)
    }

    @Test("Scroll is mutating")
    func testScrollMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("scroll") == true)
    }

    @Test("MoveMouse is mutating")
    func testMoveMouseMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("moveMouse") == true)
    }

    @Test("Screenshot is NOT mutating")
    func testScreenshotNotMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("screenshot") == false)
    }

    @Test("GetWindows is NOT mutating")
    func testGetWindowsNotMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("getWindows") == false)
    }

    @Test("FocusWindow is NOT mutating")
    func testFocusWindowNotMutating() {
        #expect(ComputerUseDetailsHelper.isMutating("focusWindow") == false)
    }

    // MARK: - Format Coordinates

    @Test("Formats integer coordinates")
    func testFormatIntCoords() {
        let result = ComputerUseDetailsHelper.formatCoordinates(x: 100.0, y: 200.0)
        #expect(result == "(100, 200)")
    }

    @Test("Formats float coordinates")
    func testFormatFloatCoords() {
        let result = ComputerUseDetailsHelper.formatCoordinates(x: 100.5, y: 200.7)
        #expect(result == "(100.5, 200.7)")
    }

    // MARK: - Format Keys

    @Test("Formats modifier + key")
    func testFormatModifierKey() {
        let result = ComputerUseDetailsHelper.formatKeys(["cmd", "c"])
        #expect(result == "Cmd+C")
    }

    @Test("Formats multi-modifier")
    func testFormatMultiModifier() {
        let result = ComputerUseDetailsHelper.formatKeys(["cmd", "shift", "s"])
        #expect(result == "Cmd+Shift+S")
    }

    @Test("Formats special keys")
    func testFormatSpecialKeys() {
        #expect(ComputerUseDetailsHelper.formatKeys(["enter"]) == "Return")
        #expect(ComputerUseDetailsHelper.formatKeys(["escape"]) == "Esc")
        #expect(ComputerUseDetailsHelper.formatKeys(["tab"]) == "Tab")
        #expect(ComputerUseDetailsHelper.formatKeys(["space"]) == "Space")
        #expect(ComputerUseDetailsHelper.formatKeys(["delete"]) == "Delete")
    }

    @Test("Formats arrow keys")
    func testFormatArrowKeys() {
        #expect(ComputerUseDetailsHelper.formatKeys(["up"]) == "↑")
        #expect(ComputerUseDetailsHelper.formatKeys(["down"]) == "↓")
        #expect(ComputerUseDetailsHelper.formatKeys(["left"]) == "←")
        #expect(ComputerUseDetailsHelper.formatKeys(["right"]) == "→")
    }

    @Test("Formats ctrl and alt modifiers")
    func testFormatCtrlAlt() {
        #expect(ComputerUseDetailsHelper.formatKeys(["ctrl", "alt", "delete"]) == "Ctrl+Opt+Delete")
    }

    @Test("Formats command alias")
    func testFormatCommandAlias() {
        #expect(ComputerUseDetailsHelper.formatKeys(["command", "v"]) == "Cmd+V")
    }

    @Test("Formats option alias")
    func testFormatOptionAlias() {
        #expect(ComputerUseDetailsHelper.formatKeys(["option", "a"]) == "Opt+A")
    }
}

// MARK: - ComputerUseSummaryHelper Tests

@Suite("ComputerUseSummaryHelper")
struct ComputerUseSummaryHelperTests {

    @Test("Screenshot summary (full screen)")
    func testScreenshotFullScreen() {
        let args = "{\"action\": \"screenshot\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "screenshot")
    }

    @Test("Screenshot summary (specific window)")
    func testScreenshotWindow() {
        let args = "{\"action\": \"screenshot\", \"window\": \"Safari\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "screenshot: Safari")
    }

    @Test("Click summary")
    func testClickSummary() {
        let args = "{\"action\": \"click\", \"x\": 100, \"y\": 200}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "click (100, 200)")
    }

    @Test("Double-click summary")
    func testDoubleClickSummary() {
        let args = "{\"action\": \"click\", \"x\": 50, \"y\": 50, \"clicks\": 2}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "double-click (50, 50)")
    }

    @Test("Type summary")
    func testTypeSummary() {
        let args = "{\"action\": \"type\", \"text\": \"hello\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "type: \"hello\"")
    }

    @Test("Type summary truncated")
    func testTypeSummaryTruncated() {
        let args = "{\"action\": \"type\", \"text\": \"this is a very long text that should be truncated in the summary display\"}"
        let summary = ComputerUseSummaryHelper.summary(from: args)
        #expect(summary.contains("..."))
        #expect(summary.hasPrefix("type: \""))
    }

    @Test("Keypress summary")
    func testKeypressSummary() {
        let args = "{\"action\": \"keypress\", \"keys\": [\"cmd\", \"c\"]}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "Cmd+C")
    }

    @Test("Scroll summary")
    func testScrollSummary() {
        let args = "{\"action\": \"scroll\", \"direction\": \"down\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "scroll down")
    }

    @Test("GetWindows summary")
    func testGetWindowsSummary() {
        let args = "{\"action\": \"getWindows\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "list windows")
    }

    @Test("FocusWindow summary")
    func testFocusWindowSummary() {
        let args = "{\"action\": \"focusWindow\", \"window\": \"Xcode\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "focus: Xcode")
    }

    @Test("MoveMouse summary")
    func testMoveMouseSummary() {
        let args = "{\"action\": \"moveMouse\", \"x\": 300, \"y\": 400}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "move to (300, 400)")
    }

    @Test("Empty action returns empty string")
    func testEmptyAction() {
        let args = "{}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "")
    }

    @Test("Unknown action returns action name")
    func testUnknownAction() {
        let args = "{\"action\": \"dance\"}"
        #expect(ComputerUseSummaryHelper.summary(from: args) == "dance")
    }
}

// MARK: - ToolRegistry ComputerUse Integration Tests

@Suite("ToolRegistry ComputerUse")
struct ToolRegistryComputerUseTests {

    @Test("ComputerUse is a command tool")
    func testIsCommandTool() {
        #expect(ToolRegistry.isCommandTool("ComputerUse") == true)
    }

    @Test("ComputerUse descriptor exists")
    func testDescriptorExists() {
        let desc = ToolRegistry.descriptor(for: "ComputerUse")
        #expect(desc.displayName == "Computer Use")
        #expect(desc.icon == "desktopcomputer")
        #expect(desc.completedDisplayName == "Used")
    }

    @Test("ComputerUse summary extractor works for click")
    func testSummaryExtractorClick() {
        let desc = ToolRegistry.descriptor(for: "ComputerUse")
        let summary = desc.summaryExtractor("{\"action\": \"click\", \"x\": 100, \"y\": 200}")
        #expect(summary == "click (100, 200)")
    }

    @Test("ComputerUse summary extractor works for keypress")
    func testSummaryExtractorKeypress() {
        let desc = ToolRegistry.descriptor(for: "ComputerUse")
        let summary = desc.summaryExtractor("{\"action\": \"keypress\", \"keys\": [\"cmd\", \"v\"]}")
        #expect(summary == "Cmd+V")
    }

    @Test("ComputerUse summary extractor works for screenshot")
    func testSummaryExtractorScreenshot() {
        let desc = ToolRegistry.descriptor(for: "ComputerUse")
        let summary = desc.summaryExtractor("{\"action\": \"screenshot\"}")
        #expect(summary == "screenshot")
    }

    @Test("ComputerUse has viewer factory")
    func testHasViewerFactory() {
        let desc = ToolRegistry.descriptor(for: "ComputerUse")
        #expect(desc.viewerFactory != nil)
    }

    @Test("ComputerUse in commandToolNames set")
    func testInCommandToolNames() {
        #expect(ToolRegistry.commandToolNames.contains("computeruse"))
    }

    @Test("ComputerUse NOT in specialToolNames set")
    func testNotInSpecialToolNames() {
        #expect(!ToolRegistry.specialToolNames.contains("computeruse"))
    }
}
