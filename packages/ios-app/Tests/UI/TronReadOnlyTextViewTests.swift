import UIKit
import Testing
@testable import TronMobile

@Suite("Native document reader chrome")
struct TronReadOnlyTextViewTests {
    @Test("reader uses explicit safe-area ownership")
    func readerUsesDocumentHostInsetContract() {
        #expect(
            TronDocumentReaderLayoutPolicy.contentInsetAdjustmentBehavior == .never
        )
    }
}
