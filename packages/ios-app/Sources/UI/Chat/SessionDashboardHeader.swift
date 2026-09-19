import SwiftUI

/// Only the backdrop observes scroll progress. Keeping this reference
/// out of the list's observed inputs avoids re-filtering sessions on every frame.
@MainActor @Observable
final class SessionDashboardHeaderState {
    static let blurFadeDistance: CGFloat = 80
    private(set) var progress: CGFloat = 0

    func update(offset: CGFloat) {
        guard offset.isFinite else { return }
        let next = min(1, max(0, offset / Self.blurFadeDistance))
        if next != progress { progress = next }
    }
}

struct SessionDashboardTitle: View {
    var body: some View {
        Text("Tron")
            .font(TronTypography.sans(size: 34, weight: .bold))
            .foregroundStyle(Color.tronEmerald)
            .fixedSize()
            // A real, fixed-size heading avoids toolbar button semantics and
            // keeps scrolling from changing the title or the content inset.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tron")
            .accessibilityAddTraits(.isHeader)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityIdentifier("dashboard.title")
    }
}

struct SessionDashboardBackdrop: View {
    let state: SessionDashboardHeaderState

    var body: some View {
        TronTopBlurOverlay(style: .dashboard)
            .opacity(state.progress)
    }
}
