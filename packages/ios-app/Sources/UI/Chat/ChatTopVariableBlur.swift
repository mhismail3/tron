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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Keep the native/variable backdrop blur unchanged. Dark mode gets
            // only a black tint over that blur so the material stays soft
            // without the regular UIBlurEffect's gray lift.
            ChatTopVariableBlur(maxBlurRadius: style.radius)
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.28),
                        Color.black.opacity(0.24),
                        Color.black.opacity(0.14),
                        Color.black.opacity(0.04),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
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
    static let pulseDuration: TimeInterval = 2.2
    static let restingTintOpacity = 0.02
    static let activeTintOpacity = 0.105
    static let reduceMotionTintOpacity = 0.06
    static let lightRestingTintOpacity = 0.045
    static let lightActiveTintOpacity = 0.18
    static let lightReduceMotionTintOpacity = 0.085

    static func height(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardHeight : bottomHeight
    }

    static func translation(keyboardVisible: Bool) -> CGFloat {
        keyboardVisible ? keyboardTranslation : bottomSafeAreaTranslation
    }

    static func pulsePhase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate / pulseDuration * 2 * Double.pi
    }
}

/// A short, nonstructural safe-area treatment. Ordinary running state changes
/// only its tint; retry, compaction, and custom working detail retain explicit
/// transcript presentation. The animation is timeline-driven so it resumes
/// when a chat returns to the foreground instead of depending on a one-shot
/// state animation that can remain at its terminal value.
struct ChatBottomActivityBlur: View {
    let isActive: Bool
    let keyboardVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !isActive || reduceMotion || scenePhase != .active
        )) { context in
            ZStack {
                ChatTopVariableBlur(maxBlurRadius: ChatBottomActivityBlurLayout.radius)
                    .rotationEffect(.degrees(180))

                // Match the top blur's dark-mode treatment. The public regular
                // blur lifts toward gray, so a black tint keeps the idle state
                // anchored to the chat background rather than changing its hue.
                if colorScheme == .dark {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.24),
                            Color.black.opacity(0.14),
                            Color.black.opacity(0.04),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.tronEmerald.opacity(tintOpacity(at: context.date)),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if isActive {
                    ChatThinkingWaveform(
                        date: context.date,
                        reduceMotion: reduceMotion
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 18)
                    .padding(.bottom, keyboardVisible ? 10 : 14)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ChatBottomActivityBlurLayout.height(keyboardVisible: keyboardVisible))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tron is working")
        .accessibilityHidden(!isActive)
    }

    private func tintOpacity(at date: Date) -> Double {
        guard isActive else { return 0 }
        if reduceMotion {
            return colorScheme == .light
                ? ChatBottomActivityBlurLayout.lightReduceMotionTintOpacity
                : ChatBottomActivityBlurLayout.reduceMotionTintOpacity
        }

        let pulse = 0.5 + 0.5 * sin(ChatBottomActivityBlurLayout.pulsePhase(at: date))
        if colorScheme == .light {
            return ChatBottomActivityBlurLayout.lightRestingTintOpacity
                + (ChatBottomActivityBlurLayout.lightActiveTintOpacity
                    - ChatBottomActivityBlurLayout.lightRestingTintOpacity) * pulse
        }
        return ChatBottomActivityBlurLayout.restingTintOpacity
            + (ChatBottomActivityBlurLayout.activeTintOpacity
                - ChatBottomActivityBlurLayout.restingTintOpacity) * pulse
    }
}

private struct ChatThinkingWaveform: View {
    let date: Date
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let pointCount = max(Int(size.width / 3), 2)
            let phase = reduceMotion
                ? 0
                : ChatBottomActivityBlurLayout.pulsePhase(at: date) * 1.35
            let centerY = size.height / 2
            var primaryWave = Path()
            var secondaryWave = Path()

            for index in 0...pointCount {
                let progress = Double(index) / Double(pointCount)
                let x = CGFloat(progress) * size.width
                let envelope = sin(progress * Double.pi)
                let primary = sin(progress * Double.pi * 5 - phase)
                let secondary = sin(progress * Double.pi * 9 - phase * 1.2)
                let primaryAmplitude = 3.0 + 4.0 * envelope
                let secondaryAmplitude = 2.0 + 3.0 * envelope
                let primaryY = centerY + CGFloat(primary * primaryAmplitude)
                let secondaryY = centerY + CGFloat(secondary * secondaryAmplitude + 1)

                if index == 0 {
                    primaryWave.move(to: CGPoint(x: x, y: primaryY))
                    secondaryWave.move(to: CGPoint(x: x, y: secondaryY))
                } else {
                    primaryWave.addLine(to: CGPoint(x: x, y: primaryY))
                    secondaryWave.addLine(to: CGPoint(x: x, y: secondaryY))
                }
            }

            // Use broad strokes and then blur the whole drawing. The result is
            // a soft traveling green waveform, not a sharp equalizer line.
            context.stroke(
                primaryWave,
                with: .color(Color.tronEmerald.opacity(reduceMotion ? 0.07 : 0.11)),
                style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                secondaryWave,
                with: .color(Color.tronEmerald.opacity(reduceMotion ? 0.035 : 0.06)),
                style: StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: 32)
        .blur(radius: reduceMotion ? 6 : 9)
        .mask {
            LinearGradient(
                colors: [.clear, .black, .black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
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
