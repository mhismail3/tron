import SwiftUI

/// Floating mic button for voice notes - smaller than plus button, emerald tint.
@available(iOS 26.0, *)
struct FloatingVoiceNotesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.4)).interactive(), in: .circle)
    }
}

#Preview {
    if #available(iOS 26.0, *) {
        ZStack {
            Color.black
            FloatingVoiceNotesButton(action: {})
        }
    }
}
