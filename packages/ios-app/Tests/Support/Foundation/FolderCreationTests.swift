import XCTest
@testable import TronMobile

/// Tests for folder creation feature - specifically the folder name validation logic
/// These tests verify:
/// - Valid folder name acceptance
/// - Invalid folder name rejection (empty and path traversal/segment separators)
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
        XCTAssertTrue(FolderNameValidator.isValid(".hidden"))
    }

    func testHiddenFolderNameDoubleDot() {
        XCTAssertFalse(FolderNameValidator.isValid(".."))
    }

    func testPathSeparatorIsInvalid() {
        XCTAssertFalse(FolderNameValidator.isValid("parent/child"))
    }

    // MARK: - Trimming Behavior

    func testTrimmedWhitespace() {
        // Leading/trailing whitespace should be trimmed
        XCTAssertTrue(FolderNameValidator.isValid("  valid-name  "))
    }

    func testTrimmedHiddenNameIsAllowed() {
        XCTAssertTrue(FolderNameValidator.isValid("  .hidden  "))
    }

    // MARK: - Error Message Tests

    func testEmptyNameErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: ""),
            "Folder name cannot be empty"
        )
    }

    func testDotDotNameErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: ".."),
            "Folder name cannot be .."
        )
    }

    func testPathSeparatorErrorMessage() {
        XCTAssertEqual(
            FolderNameValidator.validationError(for: "parent/child"),
            "Folder name cannot contain /"
        )
    }

    func testValidNameNoError() {
        XCTAssertNil(FolderNameValidator.validationError(for: "valid-name"))
    }
}
