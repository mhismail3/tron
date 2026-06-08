import XCTest
@testable import TronMobile

/// Tests for folder creation feature - specifically the folder name validation logic
/// These tests verify:
/// - Valid folder name acceptance
/// - Invalid folder name rejection (empty, hidden, invalid characters)
/// - Path construction correctness
final class FolderCreationTests: XCTestCase {

    // MARK: - Valid Folder Names

    func testValidSimpleFolderName() {
        XCTAssertTrue(FolderNameValidator.isValid("my-project"))
    }

    func testValidFolderNameWithUnderscore() {
        XCTAssertTrue(FolderNameValidator.isValid("test_folder"))
    }

    func testValidFolderNameWithNumbers() {
        XCTAssertTrue(FolderNameValidator.isValid("folder123"))
    }

    func testValidFolderNameWithSpaces() {
        XCTAssertTrue(FolderNameValidator.isValid("My Project"))
    }

    func testValidFolderNameWithMixedCase() {
        XCTAssertTrue(FolderNameValidator.isValid("MyNewFolder"))
    }

    func testValidFolderNameWithDashesAndNumbers() {
        XCTAssertTrue(FolderNameValidator.isValid("project-v2-final"))
    }

    // MARK: - Invalid Folder Names

    func testEmptyFolderName() {
        XCTAssertFalse(FolderNameValidator.isValid(""))
    }

    func testWhitespaceOnlyFolderName() {
        XCTAssertFalse(FolderNameValidator.isValid("   "))
    }

    func testHiddenFolderNameDot() {
        XCTAssertFalse(FolderNameValidator.isValid(".hidden"))
    }

    func testHiddenFolderNameDoubleDot() {
        XCTAssertFalse(FolderNameValidator.isValid(".."))
    }

    func testInvalidCharacterLessThan() {
        XCTAssertFalse(FolderNameValidator.isValid("folder<name"))
    }

    func testInvalidCharacterGreaterThan() {
        XCTAssertFalse(FolderNameValidator.isValid("folder>name"))
    }

    func testInvalidCharacterColon() {
        XCTAssertFalse(FolderNameValidator.isValid("folder:name"))
    }

    func testInvalidCharacterQuote() {
        XCTAssertFalse(FolderNameValidator.isValid("folder\"name"))
    }

    func testInvalidCharacterPipe() {
        XCTAssertFalse(FolderNameValidator.isValid("folder|name"))
    }

    func testInvalidCharacterQuestion() {
        XCTAssertFalse(FolderNameValidator.isValid("folder?name"))
    }

    func testInvalidCharacterAsterisk() {
        XCTAssertFalse(FolderNameValidator.isValid("folder*name"))
    }

    // MARK: - Trimming Behavior

    func testTrimmedWhitespace() {
        // Leading/trailing whitespace should be trimmed
        XCTAssertTrue(FolderNameValidator.isValid("  valid-name  "))
    }

    func testTrimmedResultsInHidden() {
        // After trimming, if name starts with dot, it should be invalid
        XCTAssertFalse(FolderNameValidator.isValid("  .hidden  "))
    }

    // MARK: - Error Message Tests

    func testEmptyNameErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: ""),
            "Folder name cannot be empty"
        )
    }

    func testHiddenNameErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: ".hidden"),
            "Hidden folders not allowed"
        )
    }

    func testInvalidCharacterErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: "test<name"),
            "Name contains invalid characters"
        )
    }

    func testValidNameNoError() {
        XCTAssertNil(FolderNameValidator.validationError(for: "valid-name"))
    }
}
