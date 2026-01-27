import XCTest
@testable import TronMobile

// MARK: - InputHistoryStore Tests

@MainActor
final class InputHistoryStoreTests: XCTestCase {

    var store: InputHistoryStore!

    override func setUp() async throws {
        // Clear any existing history
        UserDefaults.standard.removeObject(forKey: "tron.inputHistory")
        store = InputHistoryStore()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "tron.inputHistory")
        store = nil
    }

    // MARK: - Add to History Tests

    func test_addToHistory_addsNonEmptyInput() {
        // When
        store.addToHistory("Hello, Claude!")

        // Then
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first, "Hello, Claude!")
    }

    func test_addToHistory_ignoresEmptyInput() {
        // When
        store.addToHistory("")
        store.addToHistory("   ")
        store.addToHistory("\n\t")

        // Then
        XCTAssertEqual(store.history.count, 0)
    }

    func test_addToHistory_trimsWhitespace() {
        // When
        store.addToHistory("  Hello, Claude!  ")

        // Then
        XCTAssertEqual(store.history.first, "Hello, Claude!")
    }

    func test_addToHistory_insertsMostRecentFirst() {
        // When
        store.addToHistory("First")
        store.addToHistory("Second")
        store.addToHistory("Third")

        // Then
        XCTAssertEqual(store.history, ["Third", "Second", "First"])
    }

    func test_addToHistory_ignoresDuplicateAtTop() {
        // Given
        store.addToHistory("Same input")

        // When
        store.addToHistory("Same input")

        // Then
        XCTAssertEqual(store.history.count, 1)
    }

    func test_addToHistory_movesExistingToTop() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")
        store.addToHistory("Third")

        // When - add "First" again
        store.addToHistory("First")

        // Then - "First" should be at top, not duplicated
        XCTAssertEqual(store.history, ["First", "Third", "Second"])
    }

    func test_addToHistory_limitsTo100Items() {
        // When - add more than 100 items
        for i in 0..<110 {
            store.addToHistory("Input \(i)")
        }

        // Then
        XCTAssertEqual(store.history.count, 100)
        XCTAssertEqual(store.history.first, "Input 109")
    }

    // MARK: - Navigation Tests

    func test_navigateUp_returnsNilWhenEmpty() {
        // When
        let result = store.navigateUp(currentInput: "current")

        // Then
        XCTAssertNil(result)
    }

    func test_navigateUp_returnsFirstHistoryItem() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")

        // When
        let result = store.navigateUp(currentInput: "current")

        // Then
        XCTAssertEqual(result, "Second")
        XCTAssertEqual(store.currentIndex, 0)
    }

    func test_navigateUp_savesCurrentInput() {
        // Given
        store.addToHistory("History item")

        // When
        _ = store.navigateUp(currentInput: "my unsent input")
        let backResult = store.navigateDown()

        // Then - should return to saved input
        XCTAssertEqual(backResult, "my unsent input")
    }

    func test_navigateUp_iteratesThroughHistory() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")
        store.addToHistory("Third")

        // When
        let first = store.navigateUp(currentInput: "")
        let second = store.navigateUp(currentInput: "")
        let third = store.navigateUp(currentInput: "")
        let fourth = store.navigateUp(currentInput: "")

        // Then
        XCTAssertEqual(first, "Third")
        XCTAssertEqual(second, "Second")
        XCTAssertEqual(third, "First")
        XCTAssertNil(fourth) // End of history
    }

    func test_navigateDown_returnsNilWhenNotNavigating() {
        // When
        let result = store.navigateDown()

        // Then
        XCTAssertNil(result)
    }

    func test_navigateDown_returnsToTempInput() {
        // Given
        store.addToHistory("History item")
        _ = store.navigateUp(currentInput: "my input")

        // When
        let result = store.navigateDown()

        // Then
        XCTAssertEqual(result, "my input")
        XCTAssertEqual(store.currentIndex, -1)
    }

    func test_navigateDown_movesBackThroughHistory() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")
        store.addToHistory("Third")

        _ = store.navigateUp(currentInput: "current")
        _ = store.navigateUp(currentInput: "current")
        _ = store.navigateUp(currentInput: "current")

        // When
        let first = store.navigateDown()
        let second = store.navigateDown()
        let third = store.navigateDown()

        // Then
        XCTAssertEqual(first, "Second")
        XCTAssertEqual(second, "Third")
        XCTAssertEqual(third, "current")
    }

    // MARK: - Navigation State Tests

    func test_isNavigating_falseByDefault() {
        XCTAssertFalse(store.isNavigating)
    }

    func test_isNavigating_trueWhileNavigating() {
        // Given
        store.addToHistory("Item")

        // When
        _ = store.navigateUp(currentInput: "")

        // Then
        XCTAssertTrue(store.isNavigating)
    }

    func test_resetNavigation_resetsIndex() {
        // Given
        store.addToHistory("Item")
        _ = store.navigateUp(currentInput: "")

        // When
        store.resetNavigation()

        // Then
        XCTAssertFalse(store.isNavigating)
        XCTAssertEqual(store.currentIndex, -1)
    }

    func test_navigationPosition_showsCorrectPosition() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")
        store.addToHistory("Third")

        // When
        _ = store.navigateUp(currentInput: "")

        // Then
        XCTAssertEqual(store.navigationPosition, "1/3")
    }

    // MARK: - Clear History Tests

    func test_clearHistory_removesAllItems() {
        // Given
        store.addToHistory("First")
        store.addToHistory("Second")

        // When
        store.clearHistory()

        // Then
        XCTAssertEqual(store.history.count, 0)
    }

    func test_clearHistory_resetsNavigation() {
        // Given
        store.addToHistory("Item")
        _ = store.navigateUp(currentInput: "test")

        // When
        store.clearHistory()

        // Then
        XCTAssertFalse(store.isNavigating)
    }

    // MARK: - Persistence Tests

    func test_historyPersistsAcrossInstances() {
        // Given
        store.addToHistory("Persistent item")

        // When - create new instance
        let newStore = InputHistoryStore()

        // Then
        XCTAssertEqual(newStore.history.first, "Persistent item")
    }
}
