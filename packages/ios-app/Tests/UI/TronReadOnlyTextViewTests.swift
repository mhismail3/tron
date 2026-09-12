import Testing
@testable import TronMobile

@MainActor
@Suite("Native document reader chrome")
struct TronReadOnlyTextViewTests {
    @Test("initial content clears the header, then scrolls beneath it without reset")
    func initialInsetAndScrolledOffset() throws {
        let view = TronDocumentTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        view.font = .systemFont(ofSize: 17)
        view.text = String(repeating: "first line\n", count: 100)
        view.contentSize = CGSize(width: 320, height: 2_000)
        view.readerInset = 18
        view.topChromeInset = TronTopBlurStyle.sheet.height
        view.layoutIfNeeded()
        view.applyDocumentInsets()

        #expect(view.contentInset.top == 18)
        #expect(view.scrollIndicatorInsets.top == TronTopBlurStyle.sheet.height + 18)
        #expect(view.contentOffset.y == 0)
        let start = try #require(view.beginningOfDocument)
        let firstGlyph = view.caretRect(for: start)
        #expect(firstGlyph.minY >= TronTopBlurStyle.sheet.height)

        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        view.applyDocumentInsets()
        #expect(view.contentOffset.y == 100)
        #expect(view.textContainerInset.top == TronTopBlurStyle.sheet.height + 18)
        #expect(view.contentOffset.y == 100)
    }

    @Test("reader keeps the native document inset contract")
    func readerUsesDocumentHostInsetContract() {
        #expect(TronDocumentReaderLayoutPolicy.contentInsetAdjustmentBehavior == .never)
    }
}
