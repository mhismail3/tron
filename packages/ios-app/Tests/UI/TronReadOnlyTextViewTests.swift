import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Native document reader chrome")
struct TronReadOnlyTextViewTests {

    @Test("layout and unchanged updates never snap native bounce samples or selection")
    func rubberbandContinuity() {
        let view = reader()
        view.selectedRange = NSRange(location: 14, length: 8)
        for offset in [-40.0, -18, -17.8, -0.5, 0, 0.5, 120, 300] {
            view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            let nativeOffset = view.contentOffset.y // UIKit rounds requests to physical pixels.
            for _ in 0..<3 {
                view.readerInset = 18
                view.applyDocumentInsets()
                view.setNeedsLayout()
                view.layoutIfNeeded()
                #expect(abs(view.contentOffset.y - nativeOffset) < 0.01)
                #expect(view.selectedRange == NSRange(location: 14, length: 8))
            }
        }
    }

    private func reader() -> TronDocumentTextView {
        let view = TronDocumentTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        view.contentInsetAdjustmentBehavior = .never
        view.font = .systemFont(ofSize: 17)
        view.text = String(repeating: "first line\n", count: 100)
        view.readerInset = 18
        view.layoutIfNeeded()
        view.applyDocumentInsets()
        return view
    }
}
