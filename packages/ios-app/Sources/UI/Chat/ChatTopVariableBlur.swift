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
    case toolDetail
    case logs

    var height: CGFloat {
        switch self {
        case .chat: 176
        case .dashboard: 176
        case .sheet: 124
        case .toolDetail: 108
        case .logs: 184
        }
    }

    var radius: CGFloat {
        switch self {
        case .chat: 24
        case .dashboard: 22
        case .sheet, .toolDetail, .logs: 20
        }
    }
}

struct TronTopBlurOverlay: View {
    let style: TronTopBlurStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Keep the native/variable backdrop blur and radius unchanged.
            // Dark mode uses a dark material plus black tint so it stays soft
            // without the regular UIBlurEffect's gray lift.
            ChatTopVariableBlur(maxBlurRadius: style.radius, darkMode: colorScheme == .dark)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color.black.opacity(0.46),
                        Color.black.opacity(0.40),
                        Color.black.opacity(0.24),
                        Color.black.opacity(0.08),
                        Color.clear,
                    ]
                    : [
                        Color.tronBackground.opacity(0.98),
                        Color.tronBackground.opacity(0.94),
                        Color.tronBackground.opacity(0.72),
                        Color.tronBackground.opacity(0.28),
                        Color.clear,
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

    static func height(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardHeight : bottomHeight
    }

    static func translation(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardTranslation : bottomSafeAreaTranslation
    }
}

/// A short, nonstructural safe-area blur over the chat background. It uses
/// the same masked custom blur in both appearances, without a separate tint,
/// material overlay, or working-state animation.
struct ChatBottomActivityBlur: View {
    let isActive: Bool
    let keyboardVisible: Bool

    var body: some View {
        ChatTopVariableBlur(
            maxBlurRadius: ChatBottomActivityBlurLayout.radius,
            darkMode: false,
            fadesFromBottom: true
        )
        .frame(maxWidth: .infinity)
        .frame(height: ChatBottomActivityBlurLayout.height(keyboardVisible: keyboardVisible))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tron is working")
        .accessibilityHidden(!isActive)
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
        // NavigationStack. Global notices are owned by the scene-level window,
        // not by this visual styling modifier or a presented sheet.
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
    var darkMode = false
    var fadesFromBottom = false

    func makeUIView(context: Context) -> VariableBackdropBlurView {
        VariableBackdropBlurView(
            maxBlurRadius: maxBlurRadius,
            darkMode: darkMode,
            fadesFromBottom: fadesFromBottom
        )
    }

    func updateUIView(_ blurView: VariableBackdropBlurView, context: Context) {
        blurView.maxBlurRadius = maxBlurRadius
        blurView.darkMode = darkMode
        blurView.fadesFromBottom = fadesFromBottom
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

    var darkMode: Bool {
        didSet {
            guard darkMode != oldValue else { return }
            applyPublicEffect()
        }
    }

    var fadesFromBottom: Bool {
        didSet {
            guard fadesFromBottom != oldValue else { return }
            installEdgeMask()
            #if TRON_PRIVATE_VARIABLE_BLUR
            renderedMask = nil
            configuredRadius = nil
            #endif
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

    init(maxBlurRadius: CGFloat, darkMode: Bool = false, fadesFromBottom: Bool = false) {
        self.maxBlurRadius = maxBlurRadius
        self.darkMode = darkMode
        self.fadesFromBottom = fadesFromBottom
        #if TRON_PRIVATE_VARIABLE_BLUR
        variableBlurFilter = TronMakePrivateVariableBlurFilter()
        #endif
        super.init(effect: darkMode ? UIBlurEffect(style: .systemMaterialDark) : UIBlurEffect(style: .regular))

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
        edgeMask.startPoint = CGPoint(x: 0.5, y: fadesFromBottom ? 1 : 0)
        edgeMask.endPoint = CGPoint(x: 0.5, y: fadesFromBottom ? 0 : 1)
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

    private func applyPublicEffect() {
        effect = nil
        effect = darkMode
            ? UIBlurEffect(style: .systemMaterialDark)
            : UIBlurEffect(style: .regular)
        subviews.forEach { $0.alpha = 1 }
        installEdgeMask()
    }

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
                scale: renderedMaskScale,
                fadesFromBottom: fadesFromBottom
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
        applyPublicEffect()
    }

    private static func makeTopGradientMask(
        size: CGSize,
        scale: CGFloat,
        fadesFromBottom: Bool
    ) -> CGImage? {
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
                start: CGPoint(x: size.width / 2, y: fadesFromBottom ? size.height : 0),
                end: CGPoint(x: size.width / 2, y: fadesFromBottom ? 0 : size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }.cgImage
    }
    #endif
}
