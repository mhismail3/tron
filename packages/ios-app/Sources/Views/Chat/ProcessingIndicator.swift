import SwiftUI

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Processing")
                .font(TronTypography.caption)
                .foregroundStyle(.tronEmerald)

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.tronEmerald)
                        .frame(width: 4, height: 4)
                        .opacity(animating ? 0.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}
