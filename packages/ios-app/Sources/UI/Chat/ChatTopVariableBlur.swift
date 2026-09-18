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

    /// The band's total depth, measured from the surface's top edge. It ends
    /// where resting content begins: a presented sheet's content starts below
    /// its own inset plus the inline navigation bar (70pt) and its own padding
    /// (18pt), so the band must not reach past that or the first row reads
    /// washed out before any scrolling.
    var height: CGFloat {
        switch self {
        case .chat, .dashboard: 176
        case .sheet, .toolDetail: 88
        case .logs: 184
        }
    }

    /// The part of the band that stays fully covered: the surface's own top
    /// inset and its navigation chrome. Only the remainder is the soft edge into
    /// content. The chat/dashboard header and the logs destination keep their
    /// previous opaque depth.
    var solidHeight: CGFloat {
        switch self {
        case .chat, .dashboard, .logs: (TronTopBlurProfile.baseSolidFraction * height).rounded()
        case .sheet, .toolDetail: 70
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

/// One profile builder for both blur paths and the tint. A band holds its full
/// effect through `solidFraction` and then eases out over the remainder, so the
/// chrome is covered and resting content is not.
enum TronTopBlurProfile {
    /// The fraction every base stop is expressed against: stops at or below it
    /// belong to the solid band, later stops to the fade.
    static let baseSolidFraction: CGFloat = 0.30

    static func locations(solidFraction: CGFloat, base: [CGFloat]) -> [CGFloat] {
        let solid = min(max(solidFraction, 0), 1)
        let scale = baseSolidFraction > 0 ? solid / baseSolidFraction : 0
        let tailScale = baseSolidFraction < 1 ? (1 - solid) / (1 - baseSolidFraction) : 0
        return base.map { fraction in
            fraction <= baseSolidFraction
                ? fraction * scale
                : solid + (fraction - baseSolidFraction) * tailScale
        }
    }

    /// How much of a band stays solid before its fade, as a location fraction.
    static func solidFraction(of style: TronTopBlurStyle) -> CGFloat {
        guard style.height > 0 else { return 0 }
        return min(max(style.solidHeight / style.height, 0), 1)
    }
}

struct TronTopBlurOverlay: View {
    let style: TronTopBlurStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let solid = TronTopBlurProfile.solidFraction(of: style)
        // Dark mode uses a dark material plus black tint so it stays soft
        // without the regular UIBlurEffect's gray lift.
        let tint: [Color] = colorScheme == .dark
            ? [.black.opacity(0.46), .black.opacity(0.40), .black.opacity(0.24), .black.opacity(0.08), .clear]
            : [
                Color.tronBackground.opacity(0.98), Color.tronBackground.opacity(0.94),
                Color.tronBackground.opacity(0.72), Color.tronBackground.opacity(0.28), .clear,
            ]
        let tintLocations = TronTopBlurProfile.locations(solidFraction: solid, base: [0, 0.25, 0.5, 0.75, 1])
        let stops = Array(zip(tint, tintLocations)).map { Gradient.Stop(color: $0.0, location: $0.1) }
        ZStack {
            ChatTopVariableBlur(
                maxBlurRadius: style.radius,
                darkMode: colorScheme == .dark,
                solidFraction: solid
            )
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
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
        content
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbarBackground(.clear, for: .navigationBar, .bottomBar)
            .overlay(alignment: .top) {
                if let style { TronTopBlurOverlay(style: style) }
            }
    }
}

/// Native document readers own their initial text inset and need their host to
/// extend beneath the custom navigation blur. Keep that underlap explicit so
/// form/detail surfaces retain SwiftUI's normal safe-area placement.
private struct TronDocumentTopBlurSurfaceModifier: ViewModifier {
    @Environment(\.tronTopBlurStyle) private var style

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbarBackground(.clear, for: .navigationBar, .bottomBar)
            .overlay(alignment: .top) {
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

    /// Use only when a native document reader owns its initial inset and must
    /// scroll beneath the custom top blur after the initial position.
    func tronDocumentTopBlurSurface() -> some View {
        modifier(TronDocumentTopBlurSurfaceModifier())
    }
}

struct ChatTopVariableBlur: UIViewRepresentable {
    var maxBlurRadius: CGFloat = 18
    var darkMode = false
    var fadesFromBottom = false
    var solidFraction: CGFloat = TronTopBlurProfile.baseSolidFraction

    func makeUIView(context: Context) -> VariableBackdropBlurView {
        VariableBackdropBlurView(
            maxBlurRadius: maxBlurRadius,
            darkMode: darkMode,
            fadesFromBottom: fadesFromBottom,
            solidFraction: solidFraction
        )
    }

    func updateUIView(_ blurView: VariableBackdropBlurView, context: Context) {
        blurView.maxBlurRadius = maxBlurRadius
        blurView.darkMode = darkMode
        blurView.fadesFromBottom = fadesFromBottom
        blurView.solidFraction = solidFraction
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

    /// Fraction of the band that stays fully covered before the fade begins.
    var solidFraction: CGFloat {
        didSet {
            guard solidFraction != oldValue else { return }
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

    init(
        maxBlurRadius: CGFloat,
        darkMode: Bool = false,
        fadesFromBottom: Bool = false,
        solidFraction: CGFloat = TronTopBlurProfile.baseSolidFraction
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.darkMode = darkMode
        self.fadesFromBottom = fadesFromBottom
        self.solidFraction = solidFraction
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
        edgeMask.locations = TronTopBlurProfile.locations(
            solidFraction: solidFraction,
            base: Self.edgeMaskBaseLocations
        ).map { NSNumber(value: $0) }
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

    private static let edgeMaskBaseLocations: [CGFloat] = [0, 0.30, 0.43, 0.57, 0.69, 0.78, 0.86, 1]

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

    private static let gradientBaseLocations: [CGFloat] = [0, 0.14, 0.30, 0.46, 0.61, 0.73, 0.82, 1]

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
                fadesFromBottom: fadesFromBottom,
                solidFraction: solidFraction
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
        fadesFromBottom: Bool,
        solidFraction: CGFloat
    ) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(1, scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let locations = TronTopBlurProfile.locations(
                solidFraction: solidFraction,
                base: Self.gradientBaseLocations
            )
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
