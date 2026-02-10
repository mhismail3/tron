import SwiftUI

/// Pulsing emerald line shown when the model is thinking between visible actions.
@available(iOS 26.0, *)
struct BreathingLineIndicator: View {
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.tronEmerald)
            .frame(height: 2)
            .scaleEffect(x: 0.4, y: 1)
            .opacity(breathing ? 1.0 : 0.4)
            .padding(.vertical, 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}
