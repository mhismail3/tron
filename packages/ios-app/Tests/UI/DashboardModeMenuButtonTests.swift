import Testing
import UIKit
@testable import TronMobile

@Suite("Dashboard mode menu button")
struct DashboardModeMenuButtonTests {
    @Test("Tron logo has a bounded template intrinsic size")
    @MainActor
    func tronLogoHasBoundedTemplateIntrinsicSize() throws {
        let logo = try #require(UIImage(named: "TronLogoVector"))

        #expect(logo.size == CGSize(width: 24, height: 24))
        #expect(logo.renderingMode == .alwaysTemplate)
    }
}
