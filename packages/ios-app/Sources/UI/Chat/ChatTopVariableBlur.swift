import SwiftUI
import UIKit

enum TronTopBlurStyle {
    case chat
    case dashboard
    case sheet
    case toolDetail

    var height: CGFloat {
        switch self {
        case .chat: 176
        case .dashboard: 176
        case .sheet: 116
        case .toolDetail: 100
        }
    }

    var radius: CGFloat {
        switch self {
        case .chat: 24
        case .dashboard: 22
        case .sheet, .toolDetail: 20
        }
    }
}

struct TronTopBlurOverlay: View {
    let style: TronTopBlurStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ChatTopVariableBlur(maxBlurRadius: style.radius, darkMode: colorScheme == .dark)
            TronEdgeBlurTint(edge: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: style.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TronEdgeBlurTint: View {
    let edge: VerticalEdge
    var strength: Double = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color.black.opacity(0.46 * strength),
                    Color.black.opacity(0.40 * strength),
                    Color.black.opacity(0.24 * strength),
                    Color.black.opacity(0.08 * strength),
                    Color.clear,
                ]
                : [
                    Color.tronBackground.opacity(0.98 * strength),
                    Color.tronBackground.opacity(0.94 * strength),
                    Color.tronBackground.opacity(0.72 * strength),
                    Color.tronBackground.opacity(0.28 * strength),
                    Color.clear,
                ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }
}

enum ChatBottomActivityBlurLayout {
    static let height: CGFloat = 124
    static let translation: CGFloat = 44
}

struct ChatBottomActivityBlur: View {
    let isActive: Bool
    var height: CGFloat = ChatBottomActivityBlurLayout.height
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ChatTopVariableBlur(
                maxBlurRadius: TronTopBlurStyle.chat.radius,
                darkMode: colorScheme == .dark,
                fadesFromBottom: true
            )
            TronEdgeBlurTint(edge: .bottom, strength: 0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
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
        content.environment(\.tronTopBlurStyle, style)
    }
}

@MainActor @Observable
final class TronTopBlurFade {
    private(set) var progress: CGFloat = 0

    func update(offset: CGFloat, distance: CGFloat) {
        let next = offset.isFinite ? min(1, max(0, offset / distance)) : 0
        guard next != progress else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = next }
    }

    static func revealedOffset(offset: CGFloat, insetTop: CGFloat, insetBottom: CGFloat,
                               content: CGFloat, container: CGFloat) -> CGFloat {
        min(offset + insetTop, max(0, content + insetTop + insetBottom - container))
    }
}

struct TronTopBlurFeed {
    let fade: TronTopBlurFade
    let distance: CGFloat

    @MainActor func report(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        fade.update(offset: TronTopBlurFade.revealedOffset(
            offset: scrollView.contentOffset.y, insetTop: inset.top, insetBottom: inset.bottom,
            content: scrollView.contentSize.height, container: scrollView.bounds.height
        ), distance: distance)
    }
}

private struct TronTopBlurFeedKey: EnvironmentKey {
    static let defaultValue: TronTopBlurFeed? = nil
}

extension EnvironmentValues {
    var tronTopBlurFeed: TronTopBlurFeed? {
        get { self[TronTopBlurFeedKey.self] }
        set { self[TronTopBlurFeedKey.self] = newValue }
    }
}

@MainActor
final class TronTopBlurScrollObservation {
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var feed: TronTopBlurFeed?

    nonisolated init() {}

    func attach(_ scrollView: UIScrollView, feed: TronTopBlurFeed?) {
        self.feed = feed
        if scrollView !== self.scrollView {
            self.scrollView = scrollView
            observations = [
                scrollView.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.report() } },
                scrollView.observe(\.contentSize) { [weak self] _, _ in MainActor.assumeIsolated { self?.report() } },
            ]
        }
        report()
    }

    private func report() {
        if let scrollView { feed?.report(scrollView) }
    }
}

private struct TronTopBlurSurfaceModifier: ViewModifier {
    @Environment(\.tronTopBlurStyle) private var style
    @State private var fade = TronTopBlurFade()

    func body(content: Content) -> some View {
        let chrome = content
            .frame(maxWidth: .infinity)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbarBackground(.clear, for: .navigationBar, .bottomBar)
        if let style {
            chrome
                .environment(\.tronTopBlurFeed, TronTopBlurFeed(fade: fade, distance: style.height))
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    TronTopBlurFade.revealedOffset(
                        offset: geometry.contentOffset.y, insetTop: geometry.contentInsets.top,
                        insetBottom: geometry.contentInsets.bottom,
                        content: geometry.contentSize.height, container: geometry.containerSize.height
                    )
                } action: { _, offset in
                    fade.update(offset: offset, distance: style.height)
                }
                .overlay(alignment: .top) { TronFadingTopBlurOverlay(style: style, fade: fade) }
        } else {
            chrome
        }
    }
}

private struct TronFadingTopBlurOverlay: View {
    let style: TronTopBlurStyle
    let fade: TronTopBlurFade

    var body: some View {
        TronTopBlurOverlay(style: style)
            .opacity(fade.progress)
    }
}

private struct TronDocumentTopBlurSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .tronTopBlurSurface()
    }
}

extension View {
    func tronTopBlur(_ style: TronTopBlurStyle) -> some View {
        modifier(TronTopBlurModifier(style: style))
    }

    func tronTopBlurSurface() -> some View {
        modifier(TronTopBlurSurfaceModifier())
    }

    func tronDocumentTopBlurSurface() -> some View {
        modifier(TronDocumentTopBlurSurfaceModifier())
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
