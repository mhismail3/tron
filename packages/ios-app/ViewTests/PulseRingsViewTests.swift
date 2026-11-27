import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class PulseRingsViewTests: ShuffledTestCase {
    func testRingsStayConcentricAfterFreezeRelayoutAndRestart() throws {
        let view = TronPulseRingsView(frame: CGRect(x: 0, y: 0, width: 21.6, height: 21.6))
        view.layoutIfNeeded()
        view.update(color: UIColor.systemGreen.cgColor, animating: false)
        view.frame = CGRect(x: 0, y: 0, width: 52.8, height: 52.8)
        view.layoutIfNeeded()
        view.update(color: UIColor.systemGreen.cgColor, animating: true)
        let rings = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertEqual(rings.count, 3)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        for (index, ring) in rings.enumerated() {
            XCTAssertEqual(ring.position, center, "ring \(index) is centered")
            XCTAssertEqual(ring.bounds, view.bounds, "ring \(index) spans the view")
            XCTAssertTrue(CATransform3DIsIdentity(ring.transform), "ring \(index) scales only through its animation")
        }
    }
}
