import XCTest
@testable import TronMobile

final class TronTextEntryAlertTests: XCTestCase {
    func testManageSessionDefaultStillRejectsEmptyAndDeviceRenameCanClear() {
        let validDeviceLabel: (String) -> Bool = { value in
            value.utf8.count <= PairedDeviceCatalogPolicy.maximumNameBytes
                && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }

        XCTAssertFalse(TronTextEntryAlertAdmission.admits("   ", allowsEmpty: false, validation: { _ in true }))
        XCTAssertTrue(TronTextEntryAlertAdmission.admits("   ", allowsEmpty: true, validation: validDeviceLabel))
        XCTAssertFalse(TronTextEntryAlertAdmission.admits("Valid\u{0000}", allowsEmpty: true, validation: validDeviceLabel))
        XCTAssertFalse(TronTextEntryAlertAdmission.admits(String(repeating: "x", count: PairedDeviceCatalogPolicy.maximumNameBytes + 1), allowsEmpty: true, validation: validDeviceLabel))
        XCTAssertTrue(TronTextEntryAlertAdmission.admits("A device", allowsEmpty: true, validation: validDeviceLabel))
    }
}
