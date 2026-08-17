import SwiftUI
import UIKit

/// A top-heavy backdrop blur that eases into the unmodified transcript.
///
/// Local device builds use the technique demonstrated by
/// https://github.com/jtrivedi/VariableBlurView. Distribution builds compile
/// only the public gradient-masked `UIVisualEffectView` fallback.
enum TronTopBlurStyle {
    case chat
    case dashboard
    case sheet

    var height: CGFloat {
        switch self {
        case .chat: 188
        case .dashboard: 176
        case .sheet: 124
        }
    }

    var radius: CGFloat {
        switch self {
        case .chat: 24
        case .dashboard: 22
        case .sheet: 20
        }
    }
}

struct TronTopBlurOverlay: View {
    let style: TronTopBlurStyle

    var body: some View {
        ChatTopVariableBlur(maxBlurRadius: style.radius)
            .frame(maxWidth: .infinity)
            .frame(height: style.height)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum ChatBottomActivityBlurLayout {
    static let bottomHeight: CGFloat = 68
    static let keyboardHeight: CGFloat = 80
    static let bottomSafeAreaTranslation: CGFloat = 44
    static let keyboardTranslation: CGFloat = 24
    static let radius: CGFloat = 10
    static let pulseDuration: TimeInterval = 2.2
    static let restingTintOpacity = 0.02
    static let activeTintOpacity = 0.105
    static let reduceMotionTintOpacity = 0.06

    static func height(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardHeight : bottomHeight
    }

    static func translation(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardTranslation : bottomSafeAreaTranslation
    }
}

/// A short, nonstructural safe-area treatment. Ordinary running state changes
/// only its tint; retry, compaction, and custom working detail retain explicit
/// transcript presentation.
struct ChatBottomActivityBlur: View {
    let isActive: Bool
    let keyboardVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var emeraldPhase = false

    var body: some View {
        ZStack {
            ChatTopVariableBlur(maxBlurRadius: ChatBottomActivityBlurLayout.radius)
                .rotationEffect(.degrees(180))
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.tronEmerald.opacity(tintOpacity),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChatBottomActivityBlurLayout.height(keyboardVisible: keyboardVisible))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tron is working")
        .accessibilityHidden(!isActive)
        .onChange(of: isActive, initial: true) { _, active in
            updatePulse(active: active)
        }
        .onChange(of: reduceMotion) { _, _ in
            updatePulse(active: isActive)
        }
    }

    private var tintOpacity: Double {
        guard isActive else { return 0 }
        if reduceMotion { return ChatBottomActivityBlurLayout.reduceMotionTintOpacity }
        return emeraldPhase
            ? ChatBottomActivityBlurLayout.activeTintOpacity
            : ChatBottomActivityBlurLayout.restingTintOpacity
    }

    private func updatePulse(active: Bool) {
        guard active else {
            withAnimation(.easeOut(duration: 0.24)) { emeraldPhase = false }
            return
        }
        guard !reduceMotion else {
            emeraldPhase = true
            return
        }
        emeraldPhase = false
        withAnimation(
            .easeInOut(duration: ChatBottomActivityBlurLayout.pulseDuration)
                .repeatForever(autoreverses: true)
        ) {
            emeraldPhase = true
        }
    }
}

private struct TronTopBlurStyleKey: EnvironmentKey {
    static let defaultValue: TronTopBlurStyle? = nil
}

extension EnvironmentValues {
    var tronTopBlurStyle: TronTopBlurStyle? {
        get { self[TronTopBlurStyleKey.self] }
        set { self[TronTopBlurStyleKey.self] = newValue }
    }
}

private struct TronTopBlurModifier: ViewModifier {
    let style: TronTopBlurStyle

    func body(content: Content) -> some View {
        // The concrete ScrollView/List consumes this value inside the
        // NavigationStack. Its overlay therefore stays below toolbar chrome.
        content.environment(\.tronTopBlurStyle, style)
    }
}

private struct TronTopBlurSurfaceModifier: ViewModifier {
    @Environment(\.tronTopBlurStyle) private var style

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let style { TronTopBlurOverlay(style: style) }
        }
    }
}

extension View {
    func tronTopBlur(_ style: TronTopBlurStyle) -> some View {
        modifier(TronTopBlurModifier(style: style))
    }

    /// Use for NavigationStack content without a concrete SwiftUI scroll owner.
    func tronTopBlurSurface() -> some View {
        modifier(TronTopBlurSurfaceModifier())
    }
}

struct ChatTopVariableBlur: UIViewRepresentable {
    var maxBlurRadius: CGFloat = 18

    func makeUIView(context: Context) -> VariableBackdropBlurView {
        VariableBackdropBlurView(maxBlurRadius: maxBlurRadius)
    }

    func updateUIView(_ blurView: VariableBackdropBlurView, context: Context) {
        blurView.maxBlurRadius = maxBlurRadius
    }
}

@MainActor
final class VariableBackdropBlurView: UIVisualEffectView {
    var maxBlurRadius: CGFloat {
        didSet {
            guard maxBlurRadius != oldValue else { return }
            setNeedsLayout()
        }
    }

    private let edgeMask = CAGradientLayer()

    #if TRON_PRIVATE_VARIABLE_BLUR
    private let variableBlurFilter: NSObject?
    private var privateFilterEnabled = true
    private var configuredRadius: CGFloat?
    private var renderedMask: CGImage?
    private var renderedMaskSize = CGSize.zero
    private var renderedMaskScale: CGFloat = 0
    #endif

    init(maxBlurRadius: CGFloat) {
        self.maxBlurRadius = maxBlurRadius
        #if TRON_PRIVATE_VARIABLE_BLUR
        variableBlurFilter = TronMakePrivateVariableBlurFilter()
        #endif
        super.init(effect: UIBlurEffect(style: .regular))

        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear

        installEdgeMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        edgeMask.frame = bounds
        #if TRON_PRIVATE_VARIABLE_BLUR
        let needsMask = maskNeedsRefresh
        if privateFilterEnabled, needsMask || configuredRadius != maxBlurRadius {
            if updatePrivateFilter(forceMaskRefresh: needsMask) {
                configuredRadius = maxBlurRadius
            } else {
                privateFilterEnabled = false
                restorePublicEffect()
            }
        }
        #endif
    }

    private func installEdgeMask() {
        edgeMask.colors = Self.edgeMaskColors
        edgeMask.locations = Self.edgeMaskLocations
        edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = edgeMask
    }

    // The whole effect fades to fully transparent before its view boundary.
    // This masks the CABackdropLayer's rectangular sampling edge in addition
    // to varying the private filter's radius.
    private static let edgeMaskColors = [
        UIColor.white.cgColor,
        UIColor.white.cgColor,
        UIColor.white.withAlphaComponent(0.88).cgColor,
        UIColor.white.withAlphaComponent(0.58).cgColor,
        UIColor.white.withAlphaComponent(0.28).cgColor,
        UIColor.white.withAlphaComponent(0.08).cgColor,
        UIColor.white.withAlphaComponent(0).cgColor,
        UIColor.white.withAlphaComponent(0).cgColor,
    ]

    private static let edgeMaskLocations: [NSNumber] = [0, 0.30, 0.43, 0.57, 0.69, 0.78, 0.86, 1]

    private static let gradientColors = [
        UIColor.white.cgColor,
        UIColor.white.withAlphaComponent(0.92).cgColor,
        UIColor.white.withAlphaComponent(0.70).cgColor,
        UIColor.white.withAlphaComponent(0.43).cgColor,
        UIColor.white.withAlphaComponent(0.20).cgColor,
        UIColor.white.withAlphaComponent(0.06).cgColor,
        UIColor.white.withAlphaComponent(0).cgColor,
        UIColor.white.withAlphaComponent(0).cgColor,
    ]

    private static let gradientLocations: [NSNumber] = [0, 0.14, 0.30, 0.46, 0.61, 0.73, 0.82, 1]

    #if TRON_PRIVATE_VARIABLE_BLUR
    private var maskNeedsRefresh: Bool {
        bounds.size != renderedMaskSize || traitCollection.displayScale != renderedMaskScale
    }

    @discardableResult
    private func updatePrivateFilter(forceMaskRefresh: Bool) -> Bool {
        guard let variableBlurFilter else { return false }

        if forceMaskRefresh || renderedMask == nil {
            renderedMaskSize = bounds.size
            renderedMaskScale = traitCollection.displayScale
            renderedMask = Self.makeTopGradientMask(
                size: bounds.size,
                scale: renderedMaskScale
            )
        }
        guard let renderedMask else { return false }

        return TronConfigurePrivateVariableBlurFilter(
            variableBlurFilter,
            self,
            max(0, maxBlurRadius),
            renderedMask
        )
    }

    private func restorePublicEffect() {
        effect = nil
        effect = UIBlurEffect(style: .regular)
        subviews.forEach { $0.alpha = 1 }
        installEdgeMask()
    }

    private static func makeTopGradientMask(size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(1, scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let locations = Self.gradientLocations.map(CGFloat.init(truncating:))
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: Self.gradientColors as CFArray,
                locations: locations
            ) else { return }

            rendererContext.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: size.width / 2, y: 0),
                end: CGPoint(x: size.width / 2, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }.cgImage
    }
    #endif
}
