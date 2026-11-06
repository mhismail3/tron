import SwiftUI

/// The Sandbox's design-language tokens and primitives
/// (docs/design-language.md). Sandbox only: production keeps the shared
/// presentation owners until a change adopts a part of this language.
enum SandboxDesign {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Titles, panels and row content share one inset.
        static let inset: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 16
        static let bubble: CGFloat = 20
        static let panel: CGFloat = 28
    }

    enum Size {
        /// Every target's minimum hit region.
        static let hit: CGFloat = 44
        static let circle: CGFloat = 44
        static let smallCircle: CGFloat = 36
        static let badge: CGFloat = 24
    }

    @MainActor enum Typeface {
        static var title: Font { TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold) }
        static var focal: Font { TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold) }
        static var body: Font { TronTypography.sans(size: TronTypography.sizeBodyLG) }
        static var rowPrimary: Font { TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold) }
        static var rowSecondary: Font { TronTypography.sans(size: TronTypography.sizeSecondary) }
        static var utility: Font { TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold) }
        static var code: Font { TronTypography.code(size: TronTypography.sizeBody2) }
    }

    /// The one spring family: critically damped, from the presented value and
    /// velocity. Durations are perceptual (Apple's response), never timers.
    struct Motion: Sendable {
        var reduceMotion = false
        var slowMotion: Double = 1

        /// Resize, reflow and chip collapse.
        var geometry: Animation { spring(0.34) }
        /// One-progress transitions: the liquid menu and the feedback collapse.
        var progress: Animation { spring(0.36) }
        /// 150 ms content swap.
        var content: Animation { .easeOut(duration: 0.15 * slowMotion) }
        /// 100 ms press acknowledgement.
        var press: Animation { .easeOut(duration: 0.1) }

        private func spring(_ response: Double) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.2 * slowMotion)
                : .interpolatingSpring(duration: response * slowMotion, bounce: 0)
        }
    }
}

private struct SandboxMotionKey: EnvironmentKey {
    static let defaultValue = SandboxDesign.Motion()
}

extension EnvironmentValues {
    var sandboxMotion: SandboxDesign.Motion {
        get { self[SandboxMotionKey.self] }
        set { self[SandboxMotionKey.self] = newValue }
    }
}

/// Press feedback for every Sandbox control: scale on touch-down, 100 ms.
struct SandboxPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A glyph on a glass circle inside a 44-point hit region; the glyph does not
/// grow with Dynamic Type (the Large Content Viewer shows it). `prominent` fills it
/// with the primary ink: the screen's one primary action.
struct SandboxActionCircle: View {
    let icon: String
    let label: String
    var diameter: CGFloat = SandboxDesign.Size.circle
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: diameter * 0.36, weight: .semibold))
                .foregroundStyle(prominent ? Color.tronBackground : (isEnabled ? Color.tronTextPrimary : Color.tronTextDisabled))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .glassEffect(prominent ? .regular.tint(.tronPrimary).interactive() : .regular.interactive(), in: .circle)
                .frame(minWidth: SandboxDesign.Size.hit, minHeight: SandboxDesign.Size.hit)
                .contentShape(Circle())
        }
        .buttonStyle(SandboxPressStyle())
        .accessibilityLabel(label)
        // The glyph keeps its size in the fixed circle; at accessibility sizes a
        // long press shows it large instead.
        .accessibilityShowsLargeContentViewer {
            Image(systemName: icon)
            Text(label)
        }
    }
}
