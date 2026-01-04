import SwiftUI

// MARK: - View Extensions

extension View {
    /// Conditionally applies a modifier
    @ViewBuilder
    func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies a modifier if the value is non-nil
    @ViewBuilder
    func ifLet<T, Content: View>(
        _ value: T?,
        transform: (Self, T) -> Content
    ) -> some View {
        if let value = value {
            transform(self, value)
        } else {
            self
        }
    }

    /// Hides the view conditionally
    @ViewBuilder
    func hidden(_ hidden: Bool) -> some View {
        if hidden {
            self.hidden()
        } else {
            self
        }
    }

    /// Reads the size of a view
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }

    /// Adds a navigation back button with custom action
    func navigationBackButton(action: @escaping () -> Void) -> some View {
        navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: action) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Back")
                        }
                        .foregroundStyle(.tronMint)
                    }
                }
            }
    }

    /// Applies a shimmering loading effect
    func shimmer(active: Bool = true) -> some View {
        self.modifier(ShimmerModifier(active: active))
    }
}

// MARK: - Size Preference Key

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Shimmer Modifier

struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            .white.opacity(0.1),
                            .clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .rotationEffect(.degrees(20))
                    .offset(x: phase)
                )
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 400
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Button Styles

struct TronPrimaryButtonStyle: ButtonStyle {
    let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? .tronBackground : .tronTextDisabled)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isEnabled {
                        LinearGradient.tronEmeraldGradient
                    } else {
                        Color.tronSurfaceElevated
                    }
                }
            )
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.tronFast, value: configuration.isPressed)
    }
}

struct TronSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.tronMint)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .stroke(Color.tronMint, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.tronFast, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TronPrimaryButtonStyle {
    static var tronPrimary: TronPrimaryButtonStyle { TronPrimaryButtonStyle() }
    static func tronPrimary(isEnabled: Bool) -> TronPrimaryButtonStyle {
        TronPrimaryButtonStyle(isEnabled: isEnabled)
    }
}

extension ButtonStyle where Self == TronSecondaryButtonStyle {
    static var tronSecondary: TronSecondaryButtonStyle { TronSecondaryButtonStyle() }
}

// MARK: - Keyboard Handling

extension View {
    /// Dismisses keyboard when tapped outside
    func dismissKeyboardOnTap() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }
}
