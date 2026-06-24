import XCTest
@testable import TronMobile

final class ToastBannerLayoutTests: XCTestCase {
    func testCompactCenteredTopPillLayout() {
        XCTAssertEqual(ToastBannerLayout.topPadding, 8)
        XCTAssertEqual(ToastBannerLayout.maxWidth, 300)
        XCTAssertEqual(ToastBannerLayout.horizontalPadding, 12)
        XCTAssertEqual(ToastBannerLayout.pillCornerRadius, 22)
        XCTAssertEqual(ToastBannerLayout.contentFontSize, TronTypography.sizeBody3)
    }
}
