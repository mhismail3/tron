import SwiftUI
import UIKit

// MARK: - Semantic typography

/// Tron's established semantic type scale. Every app-owned label resolves
/// through the selected text or code family rather than a system SwiftUI font.
@MainActor
enum TronTypography {
    static let sizeXXS: CGFloat = 7
    static let sizeXS: CGFloat = 8
    static let sizeSM: CGFloat = 9
    static let sizeCaption: CGFloat = 10
    static let sizeBody2: CGFloat = 11
    static let sizeSecondary: CGFloat = 11.5
    static let sizeBodySM: CGFloat = 12
    static let sizeBody3: CGFloat = 13
    static let sizeBody: CGFloat = 14
    static let sizeBodyLG: CGFloat = 15
    static let sizeTitle: CGFloat = 16
    static let sizeLargeTitle: CGFloat = 18
    static let sizeXL: CGFloat = 20
    static let sizeXXL: CGFloat = 22
    static let sizeHero: CGFloat = 24
    static let sizeDisplay: CGFloat = 32

    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFont.body(size, weight: weight)
    }

    static func code(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFont.mono(size, weight: weight)
    }

    static var display: Font { sans(size: sizeDisplay, weight: .semibold) }
    static var largeTitle: Font { sans(size: sizeLargeTitle, weight: .bold) }
    static var headline: Font { sans(size: sizeTitle, weight: .semibold) }
    static var subheadline: Font { sans(size: sizeBody) }
    static var body: Font { sans(size: sizeBody) }
    static var bodySM: Font { sans(size: sizeBodySM) }
    /// Left-aligned secondary copy uses the selected reading family, including
    /// live state and selections. Monospace is reserved for trailing values.
    static var secondaryDescription: Font { sans(size: sizeSecondary) }
    /// A settings row's subtitle, and every sheet intro and caption: one size so
    /// explanatory copy never reads smaller than the rows around it.
    static func settingsSubtext(adjustment: CGFloat) -> Font { sans(size: sizeSecondary + adjustment) }
    /// The subtext size settings rows show inside a settings layout. Captions and
    /// New Session's setup cards use it directly so neither drifts from Settings (#939).
    static var settingsRowSubtext: Font { settingsSubtext(adjustment: TronSettingsLayoutPolicy.metadataSizeAdjustment) }
    /// Right-aligned values use the selected code family.
    static var secondaryCodeDescription: Font { code(size: sizeSecondary) }
    /// Shared section-label treatment used by every sheet and settings group.
    static var sheetSectionHeader: Font { sans(size: sizeBodySM, weight: .semibold) }
    static var caption: Font { sans(size: sizeCaption) }
    static var caption2: Font { sans(size: sizeSM) }
    static var input: Font { sans(size: sizeBodyLG) }
    static var button: Font { sans(size: sizeTitle, weight: .semibold) }
    static var buttonSM: Font { sans(size: sizeBody, weight: .semibold) }
    static var codeBlock: Font { code(size: sizeBodyLG) }
    static var codeContent: Font { code(size: sizeBody2) }
    /// Slightly larger numeric values remain legible beside dense settings rows.
    static var numericValue: Font { code(size: sizeBody3) }
    /// Shared readable scale for selectable raw JSON protocol evidence.
    static var codeJSON: Font { code(size: sizeBody3) }
}

// MARK: - App-wide surface policy

/// A progressive settings destination inherits the accent of the row that
/// opened it. Informational cards keep the same hue while shifting toward the
/// neutral slate palette so explanatory copy stays visually secondary.
struct TronSettingsVisualTheme {
    let accent: Color
    let informationalAccent: Color

    init(accent: Color) {
        self.accent = accent
        informationalAccent = accent.mix(with: .tronSlate, by: 0.58)
    }
}

// A sheet can enlarge secondary copy without changing headings or the global
// type scale. Keep this scoped to its content, not progressive destinations.
private struct TronSettingsSecondaryTextSizeAdjustmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Shared geometry for settings rows. The visible control is compact while its
/// surrounding hit target remains at least 44 points, matching Manage Session.
enum TronSettingsLayoutPolicy {
    static let metadataSizeAdjustment: CGFloat = 0.5
    static let iconSize: CGFloat = 22
    static let rowMinimumHeight: CGFloat = 48
    static let rowHorizontalPadding: CGFloat = 14
    static let dividerLeadingPadding: CGFloat = 52
    static let compactPillHeight: CGFloat = 28
    static let compactPillTargetHeight: CGFloat = 44
}

private struct TronSettingsVisualThemeKey: EnvironmentKey {
    static let defaultValue: TronSettingsVisualTheme? = nil
}

extension EnvironmentValues {
    var tronSettingsSecondaryTextSizeAdjustment: CGFloat {
        get { self[TronSettingsSecondaryTextSizeAdjustmentKey.self] }
        set { self[TronSettingsSecondaryTextSizeAdjustmentKey.self] = newValue }
    }

    var tronSettingsVisualTheme: TronSettingsVisualTheme? {
        get { self[TronSettingsVisualThemeKey.self] }
        set { self[TronSettingsVisualThemeKey.self] = newValue }
    }
}

private struct TronSettingsVisualThemeModifier: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .environment(\.tronSettingsVisualTheme, TronSettingsVisualTheme(accent: accent))
            .tint(accent)
    }
}

private struct TronInheritedSettingsVisualThemeModifier: ViewModifier {
    let fallback: Color
    @Environment(\.tronSettingsVisualTheme) private var inherited

    func body(content: Content) -> some View {
        content.tronSettingsVisualTheme(accent: inherited?.accent ?? fallback)
    }
}

private struct TronSettingsLayoutModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.tronSettingsSecondaryTextSizeAdjustment, TronSettingsLayoutPolicy.metadataSizeAdjustment)
            .controlSize(.small)
            .font(TronTypography.body)
    }
}

private struct TronSettingsAccentModifier: ViewModifier {
    let fallback: Color
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        content.foregroundStyle(settingsTheme?.accent ?? fallback)
    }
}

private struct TronPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TronTypography.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
    }
}

/// Must be attached to the scrolling content inside its NavigationStack.
/// Applying these preferences at the app root does not reliably bind the
/// scroll view to navigation chrome across sheet presentation boundaries.
private struct TronScrollEdgeChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Keep both edges softly graduated. The hard top style produces
            // an opaque cutoff on physical iOS 27 hardware instead of Tron's
            // established translucent blur into navigation chrome.
            .scrollEdgeEffectStyle(.soft, for: .all)
            .tronTopBlurSurface()
    }
}

private struct TronCollectionSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TronTypography.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
            .scrollContentBackground(.hidden)
            .background { TronBackdrop().ignoresSafeArea() }
    }
}

private struct TronGlassSurfaceModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let tintOpacity: Double
    let interactive: Bool
    let respectsSettingsTheme: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let resolvedAccent = respectsSettingsTheme ? settingsTheme?.accent ?? accent : accent
        content
            .contentShape(shape)
            .glassEffect(
                .regular.tint(resolvedAccent.opacity(tintOpacity)).interactive(interactive),
                in: shape
            )
    }
}

/// A glass-colored static surface for high-cardinality scrolling content.
/// Repeated or very tall live backdrop filters are substantially more costly
/// than their row content on device, so dense collections keep the same tint,
/// border, and geometry without installing a filter for every visible row.
private struct TronScrollSurfaceModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let tintOpacity: Double
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let resolvedAccent = settingsTheme?.accent ?? accent
        content
            .contentShape(shape)
            .background {
                shape
                    .fill(Color.tronSurfaceElevated.opacity(0.78))
                    .overlay { shape.fill(resolvedAccent.opacity(tintOpacity)) }
            }
            .overlay {
                shape.stroke(resolvedAccent.opacity(0.22), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Required at the app root so controls created by system containers inherit
    /// Tron's selected family and emerald interaction color.
    func tronPresentation() -> some View {
        modifier(TronPresentationModifier())
    }

    /// Applies the compact settings row contract without changing unrelated
    /// app surfaces. Parent settings routes opt in at their destination.
    func tronSettingsLayout() -> some View {
        modifier(TronSettingsLayoutModifier())
    }

    /// Applies one visual identity to a progressive settings destination and
    /// every nested sheet it presents.
    func tronSettingsVisualTheme(accent: Color) -> some View {
        modifier(TronSettingsVisualThemeModifier(accent: accent))
    }

    /// A settings destination's own accent, used only when nothing opened it with
    /// one (#939): opened from a Settings group, the group's accent carries through
    /// it and every sheet it presents, so no screen paints its own colour.
    func tronSettingsVisualTheme(inheriting fallback: Color) -> some View {
        modifier(TronInheritedSettingsVisualThemeModifier(fallback: fallback))
    }

    /// Resolves direct icon/action paint through the active settings theme while
    /// retaining the supplied historical color outside Settings.
    func tronSettingsAccent(_ fallback: Color = .tronEmerald) -> some View {
        modifier(TronSettingsAccentModifier(fallback: fallback))
    }

    /// Keeps tinted settings buttons legible against dark Liquid Glass while
    /// retaining their semantic or section accent in light mode.
    func tronSettingsButtonForeground(_ accent: Color) -> some View {
        modifier(TronSettingsButtonForegroundModifier(accent: accent))
    }

    /// Native top/bottom blur and fade for a scroll owner. Keep this on the
    /// concrete ScrollView/List inside NavigationStack, matching the previous
    /// non-gateway app's working toolbar-preference placement.
    func tronScrollEdgeChrome() -> some View {
        modifier(TronScrollEdgeChromeModifier())
    }

    /// Standard treatment for app-owned Form and List surfaces.
    func tronCollectionSurface() -> some View {
        modifier(TronCollectionSurfaceModifier())
    }

    /// Historical app-owned Liquid Glass surface. System toolbar controls must
    /// not use this modifier because iOS already owns their container chrome.
    func tronGlassSurface(
        accent: Color = .tronEmerald,
        cornerRadius: CGFloat = 12,
        tintOpacity: Double = 0.14,
        interactive: Bool = false,
        respectsSettingsTheme: Bool = true
    ) -> some View {
        modifier(TronGlassSurfaceModifier(
            accent: accent,
            cornerRadius: cornerRadius,
            tintOpacity: tintOpacity,
            interactive: interactive,
            respectsSettingsTheme: respectsSettingsTheme
        ))
    }

    func tronScrollSurface(
        accent: Color = .tronEmerald,
        cornerRadius: CGFloat = 12,
        tintOpacity: Double = 0.10
    ) -> some View {
        modifier(TronScrollSurfaceModifier(
            accent: accent,
            cornerRadius: cornerRadius,
            tintOpacity: tintOpacity
        ))
    }

    /// Paints a sheet's toolbar action in its title's tint (#963): pass the same
    /// `accent` the sheet gives `TronSheetTitle`, and `TronSheetTint` resolves both
    /// identically. Destructive actions stay red and neutral Close/Cancel grey; a
    /// disabled action greys itself. Never paint toolbar icons directly.
    func tronToolbarAction(accent: Color? = nil, role: TronToolbarActionRole = .standard) -> some View {
        modifier(TronToolbarActionAccent(accent: accent, role: role))
    }

    func tronNavigationTitle(_ title: String, accent: Color = .tronEmerald) -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: accent)
                }
            }
    }
}

// MARK: - Buttons

enum TronSettingsButtonContrastPolicy {
    static func usesWhiteForeground(in colorScheme: ColorScheme) -> Bool {
        colorScheme == .dark
    }
}

private struct TronSettingsButtonForegroundModifier: ViewModifier {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(
            isEnabled
                ? TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : accent
                : Color.tronTextMuted
        )
    }
}

struct TronActionButtonStyle: ButtonStyle {
    enum Role { case standard, primary, destructive }

    let role: Role
    let expands: Bool
    let explicitAccent: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    init(
        role: Role = .standard,
        expands: Bool = true,
        accent: Color? = nil
    ) {
        self.role = role
        self.expands = expands
        explicitAccent = accent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.buttonSM)
            .foregroundStyle(foreground)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 44)
            .padding(.horizontal, TronSpacing.xl)
            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
            .glassEffect(
                .regular.tint(accent.opacity(tintOpacity)).interactive(),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }

    private var accent: Color {
        if let explicitAccent { return explicitAccent }
        return switch role {
        case .standard, .primary: settingsTheme?.accent ?? Color.tronEmerald
        case .destructive: Color.tronError
        }
    }

    private var foreground: Color {
        guard isEnabled else { return .tronTextMuted }
        return TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme)
            ? .white
            : accent
    }

    private var tintOpacity: Double {
        switch role {
        case .standard: 0.16
        case .primary: 0.25
        case .destructive: 0.14
        }
    }
}

struct TronRowButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    init(accent: Color = .tronAccentText) { self.accent = accent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            .foregroundStyle(
                isEnabled
                    ? TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : accent
                    : Color.tronTextMuted
            )
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.64 : (isEnabled ? 1 : 0.48))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TronIconButtonStyle: ButtonStyle {
    let accent: Color
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    init(accent: Color = .tronEmerald, size: CGFloat = 44) {
        self.accent = accent
        self.size = max(44, size)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
            .foregroundStyle(isEnabled ? accent : .tronTextMuted)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.tint(accent.opacity(isEnabled ? 0.22 : 0.08)).interactive(), in: .circle)
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct TronPrimaryActionButton: View {
    let title: String
    let systemImage: String
    var isBusy = false
    var isEnabled = true
    var role: TronActionButtonStyle.Role = .primary
    let action: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: TronSpacing.md) {
                if isBusy {
                    TronPulseLoadingIndicator(accent: accent, size: 18)
                } else {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
        }
        .buttonStyle(TronActionButtonStyle(role: role))
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(title)
    }

    private var accent: Color {
        role == .destructive ? .tronError : settingsTheme?.accent ?? .tronEmerald
    }
}

// MARK: - Fields and editors

private struct TronFieldSurfaceModifier: ViewModifier {
    let monospaced: Bool
    let compact: Bool
    let dense: Bool
    let surfaceTint: Color
    let border: Color
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? TronTypography.code(size: TronTypography.sizeBody) : TronTypography.input)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(settingsTheme?.accent ?? .tronEmerald)
            .padding(.horizontal, compact ? TronSpacing.md : TronSpacing.section)
            .padding(.vertical, dense ? TronSpacing.xs : compact ? TronSpacing.sm : TronSpacing.md)
            .frame(minHeight: dense ? 48 : 52)
            .glassEffect(
                .regular.tint(surfaceTint),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            }
    }
}

private struct TronInlineFieldModifier: ViewModifier {
    let composer: Bool
    let monospaced: Bool
    let numeric: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    private var font: Font {
        if composer { return TronTypography.input }
        if controlSize == .small { return TronTypography.code(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment) }
        return numeric ? TronTypography.numericValue : monospaced ? TronTypography.codeContent : TronTypography.bodySM
    }

    func body(content: Content) -> some View {
        let accent = settingsTheme?.accent ?? .tronEmerald
        content
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(composer ? accent : Color.tronTextPrimary)
            .tint(accent)
    }
}
private struct TronTextEditorSurfaceModifier: ViewModifier {
    let monospaced: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        content
            .font(monospaced ? TronTypography.codeBlock : TronTypography.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(settingsTheme?.accent ?? .tronEmerald)
            .scrollContentBackground(.hidden)
            .padding(TronSpacing.md)
            .background(Color.tronSurfaceElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .stroke(Color.tronBorder.opacity(0.55), lineWidth: 0.5)
            }
    }
}

extension View {
    func tronField(
        monospaced: Bool = false,
        compact: Bool = false,
        dense: Bool = false,
        surfaceTint: Color = Color.tronSurfaceElevated.opacity(0.34),
        border: Color = Color.tronBorder.opacity(0.55)
    ) -> some View {
        modifier(TronFieldSurfaceModifier(
            monospaced: monospaced,
            compact: compact,
            dense: dense,
            surfaceTint: surfaceTint,
            border: border
        ))
    }

    /// Text input whose material is owned by a surrounding historical glass
    /// row/composer. This prevents nested field containers.
    func tronInlineField(composer: Bool = false, monospaced: Bool = false, numeric: Bool = false) -> some View {
        modifier(TronInlineFieldModifier(composer: composer, monospaced: monospaced, numeric: numeric))
    }

    func tronTextEditor(monospaced: Bool = false) -> some View {
        modifier(TronTextEditorSurfaceModifier(monospaced: monospaced))
    }

    /// The one way a settings text entry ends (#939). A single-line field's return
    /// key reads Done and commits. A multi-line field, which keeps return for
    /// newlines, and a keyboard with no return key (number pad) show Done above
    /// the keyboard instead. Either way Done runs `onDone`, then the keyboard goes
    /// away. A caller that commits on focus loss passes its focus.
    func tronTextEntryDone(
        keyboardToolbar: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onDone: @escaping () -> Void = {}
    ) -> some View {
        modifier(TronTextEntryDoneModifier(keyboardToolbar: keyboardToolbar, external: focus, onDone: onDone))
    }
}

private struct TronTextEntryDoneModifier: ViewModifier {
    let keyboardToolbar: Bool
    let external: FocusState<Bool>.Binding?
    let onDone: () -> Void
    @FocusState private var owned: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    func body(content: Content) -> some View {
        let focus = external ?? $owned
        if keyboardToolbar {
            content
                .focused(focus)
                .toolbar {
                    // Only the focused entry contributes, so sibling fields never stack Done buttons.
                    if focus.wrappedValue {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { onDone(); focus.wrappedValue = false }
                                .font(TronTypography.buttonSM)
                                .tronToolbarAction()
                                .accessibilityIdentifier("text-entry-done")
                        }
                    }
                }
        } else {
            content
                .focused(focus)
                .submitLabel(.done)
                .onSubmit { onDone(); focus.wrappedValue = false }
        }
    }
}

// MARK: - Read-only documents

enum TronReadOnlyTextStyle: Equatable, Sendable {
    case body
    case code
}

/// Native TextKit-backed document scrolling avoids asking SwiftUI to measure a
/// multi-hundred-kilobyte selectable `Text` before a sheet can present.
enum TronDocumentReaderLayoutPolicy {
    /// SwiftUI's document host owns safe-area placement; UIKit must not add a
    /// competing automatic inset that leaves a hard navigation cutoff.
    static let contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .never
}

@MainActor
final class TronDocumentTextView: UITextView {
    var readerInset: CGFloat = 18 {
        didSet { if readerInset != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        applyDocumentInsets()
        super.layoutSubviews()
    }

    func applyDocumentInsets() {
        // The native navigation safe area, not the decorative blur's full fade
        // height, owns initial glyph clearance. TextKit owns the sole horizontal
        // and top padding; duplicating it in contentInset indents twice.
        let inset = max(0, readerInset)
        let resolvedText = UIEdgeInsets(
            top: safeAreaInsets.top + inset, left: inset,
            bottom: inset, right: inset
        )
        if textContainerInset != resolvedText { textContainerInset = resolvedText }
        let resolvedContent = UIEdgeInsets(
            top: 0, left: 0, bottom: max(24, safeAreaInsets.bottom), right: 0
        )
        if contentInset != resolvedContent { contentInset = resolvedContent }
        let indicators = UIEdgeInsets(
            top: safeAreaInsets.top, left: 0, bottom: resolvedContent.bottom, right: 0
        )
        if verticalScrollIndicatorInsets != indicators { verticalScrollIndicatorInsets = indicators }
        // Never normalize contentOffset from a layout callback. Zero and the
        // negative inset edge are also legitimate samples during rubberbanding.
    }

}

struct TronReadOnlyTextView: UIViewRepresentable {
    let text: String
    var style: TronReadOnlyTextStyle = .body
    var inset: CGFloat = 18

    func makeUIView(context: Context) -> TronDocumentTextView {
        let view = TronDocumentTextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        // SwiftUI's document host owns safe-area placement and the shared
        // custom blur owns the navigation boundary. Prevent UIKit from adding
        // a second automatic scroll inset that would leave the first lines
        // below that boundary instead of behind the blur.
        view.contentInsetAdjustmentBehavior = TronDocumentReaderLayoutPolicy.contentInsetAdjustmentBehavior
        view.topEdgeEffect.style = .soft
        view.bottomEdgeEffect.style = .soft
        view.leftEdgeEffect.style = .soft
        view.rightEdgeEffect.style = .soft
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: TronDocumentTextView, context: Context) {
        view.scrollsToTop = !context.environment.chatOwnsStatusBar
        if view.text != text { view.text = text }
        let size = style == .code ? TronTypography.sizeBody3 : TronTypography.sizeBody
        let base = TronFontLoader.createUIFont(
            size: size,
            mono: style == .code
        )
        let font = UIFontMetrics(forTextStyle: style == .code ? .callout : .body)
            .scaledFont(for: base)
        if view.font?.fontName != font.fontName || view.font?.pointSize != font.pointSize {
            view.font = font
        }
        let textColor = UIColor(Color.tronTextPrimary)
        if view.textColor != textColor { view.textColor = textColor }
        let tintColor = UIColor(Color.tronEmerald)
        if view.tintColor != tintColor { view.tintColor = tintColor }
        view.readerInset = inset
        view.applyDocumentInsets()
    }
}

// MARK: - Search and selection controls

extension View {
    /// The standard commit for a sheet that edits a draft: Save at the top left,
    /// opposite the close button. Saving is never a row in the content.
    func tronSaveToolbar(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(TronSaveToolbarModifier(enabled: enabled, action: action))
    }
}

private struct TronSaveToolbarModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var theme

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: action) {
                    Text("Save")
                        .font(TronTypography.buttonSM)
                        .tronToolbarAction()
                }
                .disabled(!enabled)
                .accessibilityIdentifier("tron-sheet-save")
            }
        }
    }
}

struct TronSearchBar: View {
    @Binding var text: String
    var prompt = "Search"
    var accent: Color = .tronEmerald
    var focusOnAppear = false
    var onClose: (() -> Void)?
    var onOptions: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    @FocusState private var focused: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        let accent = settingsTheme?.accent ?? accent
        HStack(spacing: 8) {
            HStack(spacing: TronSpacing.lg) {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                TextField(
                    "",
                    text: $text,
                    prompt: Text(focused ? "" : prompt).foregroundStyle(accent.opacity(0.68))
                )
                    .textFieldStyle(.plain)
                    .font(TronTypography.body)
                    .foregroundStyle(accent)
                    .tint(accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                if !text.isEmpty {
                    Button {
                        text = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(TronTypography.body)
                            .foregroundStyle(accent.opacity(0.72))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, TronSpacing.inputHorizontal)
            .padding(.trailing, text.isEmpty ? TronSpacing.inputHorizontal : 0)
            .frame(minHeight: 44)
            .glassEffect(.regular.tint(accent.opacity(0.16)).interactive(), in: .capsule)
            .contentShape(Capsule())
            .onTapGesture { focused = true }

            if let onOptions {
                Button(action: onOptions) {
                    Image(systemName: "slider.horizontal.3")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glassEffect(.regular.tint(accent.opacity(0.12)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search options")
            }

            if let onClose {
                Button {
                    focused = false
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glassEffect(.regular.tint(accent.opacity(0.14)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
        }
        .task(id: focusOnAppear) {
            guard focusOnAppear else { return }
            await Task.yield()
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            onFocusChange?(isFocused)
        }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}


struct TronSegmentedControl<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var accent: Color = .tronEmerald
    var foreground: Color? = nil
    var minimumHeight: CGFloat = 44
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { settingsTheme?.accent ?? accent }
    private var resolvedForeground: Color { settingsTheme?.accent ?? foreground ?? .tronAccentText }

    var body: some View {
        GlassEffectContainer(spacing: TronSpacing.xs) {
            HStack(spacing: TronSpacing.xs) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let selected = selection == option.value
                    Button {
                        guard !selected else { return }
                        withAnimation(.easeOut(duration: 0.12)) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody3,
                                weight: selected ? .semibold : .medium
                            ))
                            .foregroundStyle(resolvedForeground)
                            .frame(maxWidth: .infinity, minHeight: minimumHeight)
                            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(resolvedAccent.opacity(selected ? 0.28 : 0.08)).interactive(),
                        in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    )
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Shared chrome and copy

struct TronSheetTitle: View {
    let title: String
    var accent: Color = .tronEmerald
    var icon: String? = nil
    var truncationMode: Text.TruncationMode = .tail
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { TronSheetTint.resolve(accent, theme: settingsTheme) }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(resolvedAccent)
                    .accessibilityHidden(true)
            }
            TronTitleLabel(title: title, accent: resolvedAccent, truncationMode: truncationMode)
        }
    }
}

struct TronDashboardFilterSheet<Content: View>: View {
    let title: String
    let accent: Color
    let detents: Set<PresentationDetent>
    let onDone: () -> Void
    private let content: Content
    @State private var selectedDetent: PresentationDetent = .medium

    init(
        title: String,
        accent: Color,
        detents: Set<PresentationDetent>,
        onDone: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accent = accent
        self.detents = detents
        self.onDone = onDone
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TronSpacing.xlarge)
                .padding(.vertical, TronSpacing.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tronScrollEdgeChrome()
            .tronNavigationTitle(title, accent: accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronSettingsVisualTheme(accent: accent)
        .tronTopBlur(.sheet)
        // Each presentation starts at medium. UIKit expands an upward content
        // drag before scrolling; selection changes never reset the detent.
        .presentationDetents(detents, selection: $selectedDetent)
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.hidden)
    }
}

struct TronDashboardFilterSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.xs) {
            Text(title)
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TronDashboardFilterOption: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    let accent: Color
    let inactiveAccent: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                action()
            }
        } label: {
            HStack(spacing: TronSpacing.xl) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? accent : Color.tronTextMuted)
                    .frame(width: 20, height: 20, alignment: .center)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: TronSpacing.md)
            }
            .padding(.horizontal, TronSpacing.xl)
            .padding(.vertical, TronSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .tronGlassSurface(
            accent: selected ? accent : inactiveAccent,
            cornerRadius: 12,
            tintOpacity: selected ? 0.18 : 0.08,
            interactive: true,
            respectsSettingsTheme: false
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum TronConfirmationActionPlacement: Equatable, Sendable {
    case toolbar
    case content
}

enum TronConfirmationActionPlacementPolicy {
    static func placement(
        measuredTitleWidth: CGFloat,
        toolbarBudget: CGFloat,
        isAccessibilitySize: Bool,
        containsLineBreak: Bool
    ) -> TronConfirmationActionPlacement {
        guard !isAccessibilitySize, !containsLineBreak,
              measuredTitleWidth <= toolbarBudget else { return .content }
        return .toolbar
    }

    @MainActor
    static func placement(
        for title: String,
        containerWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> TronConfirmationActionPlacement {
        let baseFont = TronFontLoader.createUIFont(
            size: TronTypography.sizeBody,
            weight: .semibold
        )
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        let measuredWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        // Reserve the center title and leading cancellation control. Capping
        // the trailing budget also prevents a wide device from turning a
        // sentence-length action back into toolbar chrome.
        let toolbarBudget = min(150, max(72, containerWidth * 0.33))
        return placement(
            measuredTitleWidth: measuredWidth,
            toolbarBudget: toolbarBudget,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            containsLineBreak: title.contains(where: \.isNewline)
        )
    }
}

struct TronConfirmationSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    let secondaryTitle: String?
    let centersTitle: Bool
    let alwaysUsesToolbarActions: Bool
    let onConfirm: () -> Void
    let onSecondary: (() -> Void)?
    let additionalContent: AnyView?
    let icon: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false,
        secondaryTitle: String? = nil,
        centersTitle: Bool = false,
        alwaysUsesToolbarActions: Bool = false,
        icon: String = "exclamationmark.triangle.fill",
        onConfirm: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil,
        additionalContent: AnyView? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.destructive = destructive
        self.secondaryTitle = secondaryTitle
        self.centersTitle = centersTitle
        self.alwaysUsesToolbarActions = alwaysUsesToolbarActions
        self.icon = icon
        self.onConfirm = onConfirm
        self.onSecondary = onSecondary
        self.additionalContent = additionalContent
    }

    var body: some View {
        GeometryReader { geometry in
            let placement = alwaysUsesToolbarActions
                ? TronConfirmationActionPlacement.toolbar
                : TronConfirmationActionPlacementPolicy.placement(
                    for: confirmTitle,
                    containerWidth: geometry.size.width,
                    dynamicTypeSize: dynamicTypeSize
                )
            NavigationStack {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: icon)
                            .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .semibold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(TronTypography.largeTitle)
                            .foregroundStyle(Color.tronTextPrimary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: centersTitle ? .infinity : nil, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message)
                            .font(TronTypography.body)
                            .foregroundStyle(Color.tronTextSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let additionalContent {
                            additionalContent
                                .frame(maxWidth: .infinity)
                        }
                        if placement == .content {
                            confirmButton
                                .buttonStyle(TronActionButtonStyle(role: destructive ? .destructive : .primary))
                                .padding(.top, 8)
                                .accessibilityIdentifier("confirmation-primary-content")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
                    .padding(24)
                }
                .tronScrollEdgeChrome()
                .tronNavigationTitle("Confirm", accent: .tronEmerald)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                            onSecondary?()
                        } label: {
                            TronToolbarTextLabel(secondaryTitle ?? "Cancel", systemImage: "xmark")
                        }
                        .tronToolbarAction(role: .neutral)
                        .accessibilityIdentifier("confirmation-cancel")
                    }
                    if placement == .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            confirmButton
                                .tronToolbarAction(accent: .tronEmerald, role: destructive ? .destructive : .standard)
                                .accessibilityIdentifier("confirmation-primary-toolbar")
                        }
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var confirmButton: some View {
        Button(role: destructive ? .destructive : nil) {
            dismiss()
            onConfirm()
        } label: {
            TronToolbarTextLabel(
                confirmTitle,
                systemImage: destructive ? "trash" : "checkmark"
            )
        }
    }

    private var accent: Color { destructive ? .tronError : .tronEmerald }
}

/// The one tint rule a sheet's title and its toolbar actions share (#963): the
/// inherited Settings tint wins, else the sheet's own accent, else emerald. Both
/// `TronSheetTitle` and `tronToolbarAction` resolve through it, so a sheet's
/// icons cannot drift from its title.
enum TronSheetTint {
    static func resolve(_ accent: Color?, theme: TronSettingsVisualTheme?) -> Color {
        theme?.accent ?? accent ?? .tronEmerald
    }
}

enum TronToolbarActionRole {
    /// Takes the sheet's tint.
    case standard
    /// Removes, stops or cancels a request: always the error red.
    case destructive
    /// Closes without acting (Cancel, Close keeping a draft): grey.
    case neutral
}

private struct TronToolbarActionAccent: ViewModifier {
    let accent: Color?
    let role: TronToolbarActionRole
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        guard isEnabled else { return .tronTextMuted }
        return switch role {
        case .standard: TronSheetTint.resolve(accent, theme: settingsTheme)
        case .destructive: .tronError
        case .neutral: .tronTextSecondary
        }
    }
}

struct TronToolbarTextLabel: View {
    let title: String
    let systemImage: String
    let isWorking: Bool

    init(_ title: String, systemImage: String, isWorking: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isWorking = isWorking
    }

    var body: some View {
        HStack(spacing: 5) {
            if isWorking {
                TronPulseLoadingIndicator(size: 18)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }
}

enum TronSaveActionPresentation {
    static let systemImage = "externaldrive"
}

struct TronReloadToolbarButton: View {
    let isReloading: Bool
    let action: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        Button(action: action) {
            if isReloading {
                TronPulseLoadingIndicator(size: 18)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(TronTypography.buttonSM)
                    .tronToolbarAction()
            }
        }
        .disabled(isReloading)
        .accessibilityLabel("Reload")
        .accessibilityValue(isReloading ? "In progress" : "")
    }
}

private struct TronTitleLabel: UIViewRepresentable {
    let title: String
    let accent: Color
    let truncationMode: Text.TruncationMode

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits.insert(.header)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeTitle, weight: .semibold)
        label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: base)
        label.text = title
        label.textColor = UIColor(accent)
        label.lineBreakMode = switch truncationMode {
        case .head: .byTruncatingHead
        case .middle: .byTruncatingMiddle
        case .tail: .byTruncatingTail
        @unknown default: .byTruncatingTail
        }
        label.accessibilityLabel = title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: min(proposal.width ?? intrinsic.width, intrinsic.width), height: intrinsic.height)
    }
}

struct TronGlassCard<Content: View>: View {
    let accent: Color
    let cornerRadius: CGFloat
    let interactive: Bool
    let content: Content
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    init(
        accent: Color = .tronEmerald,
        cornerRadius: CGFloat = 12,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(
                accent: settingsTheme?.accent ?? accent,
                cornerRadius: cornerRadius,
                tintOpacity: 0.14,
                interactive: interactive
            )
    }
}

enum TronSettingsGroupSurfaceStyle: Equatable, Sendable {
    case uncontained
    case glass
    case scrollOptimized
}

/// A small tinted label for provenance and state ("Mac", "Changed outside Tron").
/// The one tag primitive: rows attach tags with `tronSettingsRowTags`.
struct TronTagModel: Identifiable {
    let label: String
    let tint: Color
    var accessibilityText: String? = nil
    var id: String { label }
}

extension TronTagModel {
    init(_ badge: SettingsBadge) {
        label = badge.label
        tint = Self.tint(forKind: badge.kind)
        accessibilityText = badge.detail.map { "\(badge.label), \($0)" }
    }

    static func tint(forKind kind: String) -> Color {
        switch kind {
        case "layer": .tronEmerald
        case "scope": .tronCyan
        case "source": .tronPurple
        case "authority": .tronBlue
        case "state": .tronAmber
        default: .tronTextSecondary
        }
    }
}

struct TronTag: View {
    let model: TronTagModel
    init(_ model: TronTagModel) { self.model = model }

    var body: some View {
        Text(model.label)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(model.tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(model.tint.opacity(0.14)))
            .accessibilityLabel(model.accessibilityText ?? model.label)
    }
}

private struct TronSettingsRowTagsKey: EnvironmentKey {
    static let defaultValue: [TronTagModel] = []
}

extension EnvironmentValues {
    /// Tags for the nearest `TronSettingsRow`, which shows them beside its title
    /// and clears them for its trailing control and anything that control presents.
    var tronSettingsRowTags: [TronTagModel] {
        get { self[TronSettingsRowTagsKey.self] }
        set { self[TronSettingsRowTagsKey.self] = newValue }
    }
}

extension View {
    func tronSettingsRowTags(_ tags: [TronTagModel]) -> some View {
        environment(\.tronSettingsRowTags, tags)
    }
}

struct TronSettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let accent: Color
    let surfaceStyle: TronSettingsGroupSurfaceStyle
    let content: Content
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    init(
        _ title: String,
        detail: String? = nil,
        accent: Color = .tronEmerald,
        surfaceStyle: TronSettingsGroupSurfaceStyle = .glass,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.accent = accent
        self.surfaceStyle = surfaceStyle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(title)
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let detail { TronSettingsCaption(detail, inset: 0) }
            }
            switch surfaceStyle {
            case .uncontained:
                content
            case .glass:
                TronGlassCard(accent: settingsTheme?.accent ?? accent) { content }
            case .scrollOptimized:
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronScrollSurface(accent: settingsTheme?.accent ?? accent, tintOpacity: 0.10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The explanatory line under a settings section title. Sheets that build
/// their own header or intro use this so the size tracks the settings groups.
struct TronSettingsRow<Trailing: View>: View {
    /// Nil for dense lists whose rows share one kind and gain nothing from a glyph.
    let icon: String?
    let title: String
    let subtitle: String?
    let subtitleLineLimit: Int?
    /// Renders the subtitle's inline markdown (emphasis, code, links) with the
    /// chat renderer's inline parser, for rows that preview canonical text.
    let subtitleIsMarkdown: Bool
    let titleIsIdentifier: Bool
    let accent: Color
    let titleFont: Font
    let titleColor: Color
    let subtitleColor: Color
    /// Non-nil makes this a feed row (an inbox entry): a one-line title with
    /// this short value trailing on its line, the subtitle in body type, and
    /// tighter vertical insets.
    let feedTrailing: String?
    let trailing: Trailing
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    @Environment(\.controlSize) private var controlSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronSettingsRowTags) private var tags

    init(
        icon: String?,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 2,
        subtitleIsMarkdown: Bool = false,
        titleIsIdentifier: Bool = false,
        accent: Color = .tronEmerald,
        titleFont: Font = TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold),
        titleColor: Color = .tronTextPrimary,
        subtitleColor: Color = .tronTextPrimary,
        feedTrailing: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.subtitleIsMarkdown = subtitleIsMarkdown
        self.titleIsIdentifier = titleIsIdentifier
        self.accent = accent
        self.titleFont = titleFont
        self.titleColor = titleColor
        self.subtitleColor = subtitleColor
        self.feedTrailing = feedTrailing
        self.trailing = trailing()
    }

    var body: some View {
        // A compact action already owns its 44-point hit area. Pad the labels,
        // not that target, so these rows size like ordinary Session rows.
        let labelsOwnInsets = controlSize == .small && !dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            if let icon {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(settingsTheme?.accent ?? accent)
                    .frame(
                        width: TronSettingsLayoutPolicy.iconSize,
                        height: TronSettingsLayoutPolicy.iconSize,
                        alignment: .center
                    )
                    .accessibilityHidden(true)
            }
            // At accessibility sizes a trailing control that competes with the
            // labels sits below them, so titles wrap only at word boundaries (#868).
            TronSettingsRowLayout(
                spacing: TronSpacing.xl,
                stackedSpacing: dynamicTypeSize.isAccessibilitySize ? TronSpacing.md : nil
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    if titleIsIdentifier && !title.contains(where: \.isWhitespace) {
                        // Opaque sources are one token, never broken at a slash
                        // or hyphen. Prose still wraps naturally at large text.
                        ScrollView(.horizontal) {
                            Text(title).font(titleFont).foregroundStyle(titleColor)
                                .fixedSize(horizontal: true, vertical: true)
                                .textSelection(.enabled)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .accessibilityLabel(title)
                    } else if let feedTrailing {
                        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
                            Text(title).font(titleFont).foregroundStyle(titleColor)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(feedTrailing)
                                .font(TronTypography.settingsSubtext(adjustment: secondaryTextSizeAdjustment))
                                .foregroundStyle(Color.tronTextMuted)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    } else {
                        Text(title).font(titleFont).foregroundStyle(titleColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle {
                        Text(subtitleIsMarkdown
                             ? MarkdownPresentation.Inline(source: subtitle).attributedString ?? AttributedString(subtitle)
                             : AttributedString(subtitle))
                            .font(feedTrailing == nil
                                ? TronTypography.settingsSubtext(adjustment: secondaryTextSizeAdjustment)
                                : TronTypography.body)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(subtitleLineLimit)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: subtitleLineLimit == nil)
                    }
                    // Tags are a row's last content: left-aligned under its text.
                    if !tags.isEmpty { tagList.padding(.top, 3) }
                }
                .padding(.vertical, labelsOwnInsets ? TronSpacing.xl : 0)
                // One subview for the layout, however many views the caller passed.
                HStack(spacing: TronSpacing.md) { trailing }
                    .environment(\.tronSettingsRowTags, [])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, labelsOwnInsets ? 0 : feedTrailing == nil ? TronSpacing.xl : TronSpacing.md)
        .frame(maxWidth: .infinity, minHeight: TronSettingsLayoutPolicy.rowMinimumHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A settings row's labels and trailing control. The control keeps its natural
/// width when both fit on one line, so the subtitle uses the rest of the row.
/// When they compete, the control caps at 45% and truncates; with
/// `stackedSpacing` (accessibility sizes) it moves below the labels instead,
/// leading-aligned at its natural width.
private struct TronSettingsRowLayout: Layout {
    let spacing: CGFloat
    let stackedSpacing: CGFloat?

    private struct Arrangement {
        var labels: CGFloat
        var trailing: CGFloat
        var stacked = false
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> Arrangement {
        guard subviews.count == 2 else { return Arrangement(labels: width, trailing: 0) }
        let trailingIdeal = subviews[1].sizeThatFits(.unspecified).width
        guard trailingIdeal > 0.5 else { return Arrangement(labels: width, trailing: 0) }
        let available = max(0, width - spacing)
        let labelsIdeal = subviews[0].sizeThatFits(.unspecified).width
        if labelsIdeal + trailingIdeal <= available {
            // A flexible control (a field) may take the room the labels leave.
            let room = available - labelsIdeal
            let trailing = max(trailingIdeal, min(room, subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)).width))
            return Arrangement(labels: available - trailing, trailing: trailing)
        }
        if stackedSpacing != nil {
            return Arrangement(labels: width, trailing: min(trailingIdeal, width), stacked: true)
        }
        let trailing = min(trailingIdeal, available * 0.45)
        return Arrangement(labels: available - trailing, trailing: trailing)
    }

    private func heights(_ subviews: Subviews, _ arrangement: Arrangement) -> (labels: CGFloat, trailing: CGFloat) {
        (subviews.first?.sizeThatFits(ProposedViewSize(width: arrangement.labels, height: nil)).height ?? 0,
         subviews.count == 2 ? subviews[1].sizeThatFits(ProposedViewSize(width: arrangement.trailing, height: nil)).height : 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing
        let arrangement = arrange(subviews, in: width)
        let (labels, trailing) = heights(subviews, arrangement)
        let height = arrangement.stacked ? labels + (stackedSpacing ?? 0) + trailing : max(labels, trailing)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, in: bounds.width)
        if arrangement.stacked {
            let (labels, _) = heights(subviews, arrangement)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: arrangement.labels, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + labels + (stackedSpacing ?? 0)), anchor: .topLeading,
                              proposal: ProposedViewSize(width: arrangement.trailing, height: nil))
            return
        }
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: arrangement.labels, height: nil))
        if subviews.count == 2 {
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: arrangement.trailing, height: nil))
        }
    }
}

private extension TronSettingsRow {
    var tagList: some View { TronTagList(tags: tags) }
}

/// A row's source and state tags, left-aligned as its last content: one line when
/// they fit, else one per line. Settings rows and setup cards place them the same way.
struct TronTagList: View {
    let tags: [TronTagModel]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(tags) { TronTag($0) } }
            VStack(alignment: .leading, spacing: 4) { ForEach(tags) { TronTag($0) } }
        }
    }
}

/// One setup choice on New Session (#939): a tinted icon and title on the left,
/// the chosen value large and trailing, the subtext beneath in the settings row
/// subtext size, and any source tags after it as on a settings row. Every card,
/// whether it opens a picker or a settings sheet, is this one label.
struct TronSetupCardLabel: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let accent: Color
    var tags: [TronTagModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                Spacer(minLength: 10)
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .truncationMode(.middle)
            }
            .foregroundStyle(accent)
            HStack(alignment: .top, spacing: 8) {
                Color.clear.frame(width: 16, height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(caption)
                        .font(TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !tags.isEmpty { TronTagList(tags: tags) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tronGlassSurface(accent: accent, cornerRadius: 12, tintOpacity: 0.15, interactive: true)
    }
}

extension TronSettingsRow where Trailing == EmptyView {
    init(
        icon: String?,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 2,
        subtitleIsMarkdown: Bool = false,
        titleIsIdentifier: Bool = false,
        accent: Color = .tronEmerald,
        titleFont: Font = TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold),
        titleColor: Color = .tronTextPrimary,
        subtitleColor: Color = .tronTextPrimary,
        feedTrailing: String? = nil
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            subtitleIsMarkdown: subtitleIsMarkdown,
            titleIsIdentifier: titleIsIdentifier,
            accent: accent,
            titleFont: titleFont,
            titleColor: titleColor,
            subtitleColor: subtitleColor,
            feedTrailing: feedTrailing
        ) { EmptyView() }
    }
}

struct TronInfoCard: View {
    let icon: String
    let text: String
    var accent: Color = .tronCyan
    var usesSemanticAccent = false
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color {
        guard !usesSemanticAccent else { return accent }
        return settingsTheme?.informationalAccent ?? accent
    }

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(resolvedAccent)
                .frame(width: 22, height: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(
            accent: resolvedAccent,
            tintOpacity: 0.09,
            respectsSettingsTheme: false
        )
    }
}

struct TronSettingsDivider: View {
    var accent: Color = .tronEmerald
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        Divider()
            .overlay((settingsTheme?.accent ?? accent).opacity(0.14))
            .padding(.leading, TronSettingsLayoutPolicy.dividerLeadingPadding)
    }
}

enum TronSettingsValuePlacement: Equatable, Sendable {
    case secondaryLine
    case trailing
}

enum TronSettingsRowSemantics {
    static func valuePlacement(hasTrailingControl: Bool) -> TronSettingsValuePlacement {
        hasTrailingControl ? .secondaryLine : .trailing
    }
}

/// A live or user-selectable value. Values are always code-family and trailing
/// aligned when a row has no separate trailing control.
struct TronDynamicValue: View {
    let text: String
    var color: Color = .tronTextPrimary
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    var body: some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .multilineTextAlignment(.trailing)
            .minimumScaleFactor(0.75)
    }
}

struct TronValueRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let value: String?
    private let valuePlacement: TronSettingsValuePlacement
    let accent: Color
    let trailing: Trailing
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        value: String? = nil,
        accent: Color = .tronEmerald,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.value = value
        valuePlacement = TronSettingsRowSemantics.valuePlacement(hasTrailingControl: true)
        self.accent = accent
        self.trailing = trailing()
    }

    private init(
        icon: String,
        title: String,
        detail: String?,
        value: String?,
        valuePlacement: TronSettingsValuePlacement,
        accent: Color,
        trailing: Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.value = value
        self.valuePlacement = valuePlacement
        self.accent = accent
        self.trailing = trailing
    }

    private var secondaryText: String? {
        switch valuePlacement {
        case .secondaryLine: value ?? detail
        case .trailing: detail
        }
    }

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: secondaryText, accent: accent) {
            if valuePlacement == .trailing, let value, !value.isEmpty {
                TronDynamicValue(text: value).layoutPriority(1)
            }
            trailing
        }
    }
}

extension TronValueRow where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        detail: String? = nil,
        value: String? = nil,
        accent: Color = .tronEmerald
    ) {
        self.init(
            icon: icon,
            title: title,
            detail: detail,
            value: value,
            valuePlacement: TronSettingsRowSemantics.valuePlacement(hasTrailingControl: false),
            accent: accent,
            trailing: EmptyView()
        )
    }
}

enum TronToggleMotionPolicy {
    static let controlWidth: CGFloat = 50
    static let controlHeight: CGFloat = 30
    static let stretchedThumbScale: CGFloat = 1.16

    static func thumbScale(isStretched: Bool, reduceMotion: Bool) -> CGFloat {
        reduceMotion || !isStretched ? 1 : stretchedThumbScale
    }
}

enum TronToggleContrastPolicy {
    static func trackColor(isOn: Bool, accent: Color, colorScheme: ColorScheme) -> Color {
        guard colorScheme == .dark else { return accent.opacity(isOn ? 0.28 : 0.08) }
        return isOn ? accent.opacity(0.52) : Color.white.opacity(0.18)
    }

    static func thumbColor(isOn: Bool, accent: Color, colorScheme: ColorScheme) -> Color {
        guard colorScheme == .dark else { return isOn ? accent : Color.tronTextMuted }
        return isOn ? .white : Color.white.opacity(0.78)
    }
}

struct TronToggleControl: View {
    let isOn: Bool
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(TronToggleContrastPolicy.trackColor(
                isOn: isOn,
                accent: accent,
                colorScheme: colorScheme
            ))
            Circle()
                .fill(TronToggleContrastPolicy.thumbColor(
                    isOn: isOn,
                    accent: accent,
                    colorScheme: colorScheme
                ))
                .padding(4)
                .phaseAnimator([false, true, false], trigger: isOn) { thumb, isStretched in
                    thumb.scaleEffect(
                        x: TronToggleMotionPolicy.thumbScale(
                            isStretched: isStretched,
                            reduceMotion: reduceMotion
                        ),
                        y: 1
                    )
                } animation: { isStretched in
                    if reduceMotion {
                        .linear(duration: 0.01)
                    } else if isStretched {
                        .smooth(duration: 0.09)
                    } else {
                        .spring(duration: 0.16, bounce: 0.18)
                    }
                }
        }
        .frame(
            width: TronToggleMotionPolicy.controlWidth,
            height: TronToggleMotionPolicy.controlHeight
        )
        .glassEffect(.regular.tint(accent.opacity(isOn ? 0.14 : 0.05)), in: Capsule())
        .animation(reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.18), value: isOn)
        .accessibilityHidden(true)
    }
}

struct TronToggleRow: View {
    let icon: String
    let title: String
    let detail: String?
    let accent: Color
    var isEnabled = true
    @Binding var isOn: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        accent: Color = .tronEmerald,
        isEnabled: Bool = true,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accent = accent
        self.isEnabled = isEnabled
        _isOn = isOn
    }

    var body: some View {
        let resolvedAccent = settingsTheme?.accent ?? accent
        Button { isOn.toggle() } label: {
            TronValueRow(icon: icon, title: title, detail: detail, accent: resolvedAccent) {
                TronToggleControl(isOn: isOn, accent: resolvedAccent)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { Text(title) }
                .disabled(!isEnabled)
                .accessibilityHint(detail ?? "")
        }
    }
}

struct TronInlineMenu<Content: View>: View {
    let title: String
    let accent: Color
    let content: Content

    init(_ title: String, accent: Color = .tronAccentText, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        Menu { content } label: {
            TronInlineActionLabel(title, accent: accent)
        }
        .accessibilityLabel(title)
    }
}

/// A shared visual label for menus and sheet actions. Small controls have a
/// slimmer capsule, not a smaller tap target.
struct TronInlineActionLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let usesSemanticAccent: Bool
    let title: String
    var icon: String?
    var isWorking = false
    var accent: Color = .tronEmerald
    /// Optional local override for surfaces whose type scale differs from the
    /// shared compact-control default (for example, in-app notices).
    var fontSize: CGFloat?
    @Environment(\.controlSize) private var controlSize
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    init(_ title: String, icon: String? = nil, isWorking: Bool = false, fontSize: CGFloat? = nil, accent: Color = .tronEmerald, usesSemanticAccent: Bool = false) {
        self.usesSemanticAccent = usesSemanticAccent
        self.title = title
        self.icon = icon
        self.isWorking = isWorking
        self.fontSize = fontSize
        self.accent = accent
    }

    var body: some View {
        let resolvedAccent = settingsTheme?.accent ?? accent
        HStack(spacing: 5) {
            if isWorking {
                TronPulseLoadingIndicator(accent: resolvedAccent, size: 14)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(TronTypography.sans(size: fontSize ?? TronTypography.sizeBodySM, weight: .semibold))
        .foregroundStyle(isEnabled
            ? (!usesSemanticAccent && TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme) ? .white : resolvedAccent)
            : Color.tronTextMuted)
        .padding(.horizontal, 10)
        .frame(minHeight: controlSize == .small ? TronSettingsLayoutPolicy.compactPillHeight : 36)
        .glassEffect(.regular.tint(resolvedAccent.opacity(0.10)).interactive(), in: Capsule())
        .padding(
            .vertical,
            controlSize == .small
                ? (TronSettingsLayoutPolicy.compactPillTargetHeight - TronSettingsLayoutPolicy.compactPillHeight) / 2
                : 0
        )
        .contentShape(Rectangle())
    }
}

struct TronCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum TronDashboardContentMotion {
    static let duration: TimeInterval = 0.28

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: duration)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    /// The pause between consecutive sections of a dashboard view's first
    /// appearance. Reduce Motion drops the stagger and keeps only the fade.
    static let sectionStaggerStep: TimeInterval = 0.08

    /// When a section's reveal has finished, measured from the view's reveal
    /// start; a row created after it renders without fading.
    static func sectionRevealEnd(order: Int) -> TimeInterval {
        Double(max(order, 0)) * sectionStaggerStep + duration
    }
}

/// Fades one dashboard section in at its place in the view's stagger, with the
/// same opacity and scale as `TronDashboardContentMotion.transition`.
///
/// The dashboard owns one reveal start per entry into its view (nil while the
/// view is not on screen). A list mounts its rows lazily, often after that start
/// is published, so each row decides once, when it is created: a row created
/// before its section's reveal has finished fades in on the shared schedule; a
/// row created later (scrolled into view, recycled, or a live catalog insert,
/// which the list's own insertion animates) renders as is. Refreshes therefore
/// never re-fade content.
struct TronDashboardSectionReveal: ViewModifier {
    let order: Int
    let revealStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool

    init(order: Int, revealStart: Date?) {
        self.order = order
        self.revealStart = revealStart
        _shown = State(initialValue: revealStart.map {
            Date().timeIntervalSince($0) > TronDashboardContentMotion.sectionRevealEnd(order: order)
        } ?? false)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985)
            .onAppear { reveal() }
            .onChange(of: revealStart) { _, _ in reveal() }
    }

    private func reveal() {
        guard !shown, let revealStart else { return }
        // Keep the section's place in the schedule however late the row mounts.
        let elapsed = max(0, Date().timeIntervalSince(revealStart))
        let animation = reduceMotion
            ? TronDashboardContentMotion.animation(reduceMotion: true)
            : TronDashboardContentMotion.animation(reduceMotion: false)
                .delay(max(0, Double(order) * TronDashboardContentMotion.sectionStaggerStep - elapsed))
        withAnimation(animation) { shown = true }
        #if HOSTED_TEST
        TronDashboardRevealProbe.shared.reveals.append(order)
        #endif
    }
}

#if HOSTED_TEST
/// Every reveal animation a mounted section view started, by stagger order, so
/// UI journeys prove the order and that live refreshes start none.
@MainActor @Observable
final class TronDashboardRevealProbe {
    static let shared = TronDashboardRevealProbe()
    var reveals: [Int] = []

    /// The distinct stagger orders revealed and the total reveal count.
    var summary: String {
        "orders:\(Set(reveals).sorted().map(String.init).joined(separator: ",")) reveals:\(reveals.count)"
    }
}
#endif

extension View {
    func tronDashboardSectionReveal(order: Int, revealStart: Date?) -> some View {
        modifier(TronDashboardSectionReveal(order: order, revealStart: revealStart))
    }
}

/// A dependency-free, concentric pulse inspired by the requested loading
/// treatment. One Canvas draws all three waves; TimelineView supplies a
/// lifecycle-bound clock without retaining per-indicator animation tasks.
enum TronPulseLoadingIndicatorEngine {
    static let pulseCount = 3
    static let cycleDuration = 1.6
    static let visualFootprintScale: CGFloat = 1.2

    static func visualSize(for requestedSize: CGFloat) -> CGFloat {
        requestedSize * visualFootprintScale
    }

    static func animationPaused(
        reduceMotion: Bool,
        sceneActive: Bool,
        surfaceActive: Bool = true
    ) -> Bool {
        reduceMotion || !sceneActive || !surfaceActive
    }

    static func progress(pulse: Int, time: Double) -> Double {
        let offset = Double(pulse) / Double(pulseCount)
        let raw = time / cycleDuration - offset
        return raw - floor(raw)
    }

    static func scale(progress: Double) -> Double {
        0.08 + 0.92 * min(1, max(0, progress))
    }

    static func opacity(progress: Double) -> Double {
        let remaining = 1 - min(1, max(0, progress))
        return 0.62 * remaining * remaining
    }
}

struct TronPulseLoadingIndicator: View {
    var accent: Color = .tronEmerald
    var size: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var isVisible = false

    var body: some View {
        let resolvedAccent = settingsTheme?.accent ?? accent
        let visualSize = TronPulseLoadingIndicatorEngine.visualSize(for: size)
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: TronPulseLoadingIndicatorEngine.animationPaused(
                reduceMotion: reduceMotion,
                sceneActive: scenePhase == .active,
                surfaceActive: presentationActivity.allowsContinuousAnimation && isVisible
            )
        )) { _ in
            Canvas(rendersAsynchronously: true) { context, canvasSize in
                let diameter = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                if reduceMotion {
                    let radius = diameter * 0.24
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .color(resolvedAccent.opacity(0.72))
                    )
                } else {
                    let time = ProcessInfo.processInfo.systemUptime
                    for pulse in 0..<TronPulseLoadingIndicatorEngine.pulseCount {
                        let progress = TronPulseLoadingIndicatorEngine.progress(
                            pulse: pulse,
                            time: time
                        )
                        let radius = diameter * 0.5
                            * TronPulseLoadingIndicatorEngine.scale(progress: progress)
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )),
                            with: .color(resolvedAccent.opacity(
                                TronPulseLoadingIndicatorEngine.opacity(progress: progress)
                            ))
                        )
                    }
                }
            }
        }
        .frame(width: visualSize, height: visualSize)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
    }
}

/// Full-content empty and unavailable states share typography, not a nested card.
/// Inline explanations and actionable settings errors remain captions/notices.
struct TronPlaceholderState: View {
    let title: String
    var detail: String? = nil
    let icon: String
    var accent: Color? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        VStack(spacing: TronSpacing.md) {
            VStack(spacing: TronSpacing.md) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: 34, weight: .medium))
                    .foregroundStyle(accent ?? settingsTheme?.accent ?? .tronSlate)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(title)
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            // Keep recovery independently reachable by VoiceOver.
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(TronActionButtonStyle(expands: false))
            }
        }
        .padding(TronSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Whole-content loading for a sheet or sub-sheet. The placeholder takes no
/// layout space; it asks the enclosing presentation surface to draw the
/// chat-opening pulse centered over the whole visible sheet. Centering at the
/// surface, not inside the sheet's scroll/stack, keeps it still across medium,
/// large and in-flight detents and means arriving content never shifts layout.
/// The accent resolves exactly like `TronSheetTitle`, so pass the title's accent.
/// Partial, in-section loads use `TronLoadingState` instead.
struct TronSheetLoadingState: View {
    let label: String
    var accent: Color = .tronEmerald
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .preference(
                key: TronSheetLoadingPreferenceKey.self,
                value: TronSheetLoadingRequest(label: label, accent: settingsTheme?.accent ?? accent)
            )
    }
}

struct TronSheetLoadingRequest: Equatable {
    let label: String
    let accent: Color
}

struct TronSheetLoadingPreferenceKey: PreferenceKey {
    static let defaultValue: TronSheetLoadingRequest? = nil
    // One pulse per sheet: the first (outermost/earliest) request wins.
    static func reduce(value: inout TronSheetLoadingRequest?, nextValue: () -> TronSheetLoadingRequest?) {
        if value == nil { value = nextValue() }
    }
}

/// Owned by `TronPresentationSurface` (every managed sheet and the app shell):
/// draws the one centered pulse a surface's content requests and consumes the
/// request so an outer surface cannot repeat it.
struct TronSheetLoadingHostModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TronSheetLoadingPreferenceKey.self) { request in
                ZStack {
                    if let request {
                        // The same indicator and size the chat opening surface uses.
                        TronPulseLoadingIndicator(accent: request.accent, size: 44)
                            .padding(18)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(request.label)
                            .accessibilityIdentifier("sheet-loading")
                            .transition(.opacity)
                    }
                }
                // No background: the native sheet material stays the only surface (#843).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
                           value: request != nil)
            }
            #if HOSTED_TEST
            // Exposes the exact area the pulse is centered in so UI journeys measure
            // centering. Behind the content, so toolbar controls stay on top.
            .backgroundPreferenceValue(TronSheetLoadingPreferenceKey.self) { request in
                if request != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .accessibilityElement()
                        .accessibilityIdentifier("sheet-loading-surface")
                }
            }
            #endif
            .transformPreference(TronSheetLoadingPreferenceKey.self) { $0 = nil }
    }
}

/// A partial load inside an already-visible sheet section: the pulse alone, with
/// its label kept for VoiceOver so it can never wrap or crowd the row.
struct TronLoadingState: View {
    let label: String
    var accent: Color = .tronEmerald
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        TronPulseLoadingIndicator(accent: settingsTheme?.accent ?? accent)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

/// A compact state label for a header or row: Home's state, a chapter's state,
/// a task's lifecycle. The pill's text is its whole label.
struct TronStatusPill: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.16)))
            .accessibilityLabel(text)
    }
}
