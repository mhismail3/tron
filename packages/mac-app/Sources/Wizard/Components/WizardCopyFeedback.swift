import AppKit
import SwiftUI

enum WizardCopyFeedback {
    static let checkInAnimationSeconds = 0.06
    static let checkOutAnimationSeconds = 0.12
    static let checkHoldNanoseconds: UInt64 = 2_000_000_000

    @MainActor
    static func copy<Mark: Equatable>(_ text: String, mark state: Binding<Mark>, as value: Mark, clearTo cleared: Mark) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        withAnimation(.snappy(duration: checkInAnimationSeconds)) {
            state.wrappedValue = value
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: checkHoldNanoseconds)
            guard state.wrappedValue == value else { return }
            withAnimation(.snappy(duration: checkOutAnimationSeconds)) {
                state.wrappedValue = cleared
            }
        }
    }
}
