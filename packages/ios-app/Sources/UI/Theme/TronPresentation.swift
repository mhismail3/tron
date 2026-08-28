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
    /// Stable explanatory copy and labels use the selected reading family.
    static var secondaryDescription: Font { sans(size: sizeSecondary) }
    /// Live or user-selectable values use the selected code family so state is
    /// visually distinct from stable explanatory copy.
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
    @Environment(\.tronTopBlurStyle) private var topBlurStyle

    func body(content: Content) -> some View {
        content
            // Keep both edges softly graduated. The hard top style produces
            // an opaque cutoff on physical iOS 27 hardware instead of Tron's
            // established translucent blur into navigation chrome.
            .scrollEdgeEffectStyle(.soft, for: .all)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let topBlurStyle {
                    TronTopBlurOverlay(style: topBlurStyle)
                }
            }
    }
}

private struct TronCollectionSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TronTypography.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
    }
}

private struct TronGlassSurfaceModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let tintOpacity: Double
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .contentShape(shape)
            .glassEffect(
                .regular.tint(accent.opacity(tintOpacity)).interactive(interactive),
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

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .contentShape(shape)
            .background {
                shape
                    .fill(Color.tronSurfaceElevated.opacity(0.78))
                    .overlay { shape.fill(accent.opacity(tintOpacity)) }
            }
            .overlay {
                shape.stroke(accent.opacity(0.22), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Required at the app root so controls created by system containers inherit
    /// Tron's selected family and emerald interaction color.
    func tronPresentation() -> some View {
        modifier(TronPresentationModifier())
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
        interactive: Bool = false
    ) -> some View {
        modifier(TronGlassSurfaceModifier(
            accent: accent,
            cornerRadius: cornerRadius,
            tintOpacity: tintOpacity,
            interactive: interactive
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

    func tronToolbarAction(accent: Color = .tronEmerald) -> some View {
        foregroundStyle(accent)
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

struct TronActionButtonStyle: ButtonStyle {
    enum Role { case standard, primary, destructive }

    let role: Role
    let expands: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(role: Role = .standard, expands: Bool = true) {
        self.role = role
        self.expands = expands
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
        switch role {
        case .standard, .primary: .tronEmerald
        case .destructive: .tronError
        }
    }

    private var foreground: Color {
        guard isEnabled else { return .tronTextMuted }
        return role == .destructive ? .tronError : .tronAccentText
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

    init(accent: Color = .tronAccentText) { self.accent = accent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            .foregroundStyle(isEnabled ? accent : Color.tronTextMuted)
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

    private var accent: Color { role == .destructive ? .tronError : .tronEmerald }
}

// MARK: - Fields and editors

private struct TronFieldSurfaceModifier: ViewModifier {
    let monospaced: Bool
    let compact: Bool
    let dense: Bool
    let surfaceTint: Color
    let border: Color

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? TronTypography.code(size: TronTypography.sizeBody) : TronTypography.input)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
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

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(composer ? TronTypography.input : numeric ? TronTypography.numericValue : monospaced ? TronTypography.codeContent : TronTypography.bodySM)
            .foregroundStyle(composer ? Color.tronEmerald : Color.tronTextPrimary)
            .tint(Color.tronEmerald)
    }
}

private struct TronComposerFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(TronTypography.input)
            .foregroundStyle(Color.tronAccentText)
            .tint(Color.tronEmerald)
            .padding(.horizontal, TronSpacing.inputHorizontal)
            .padding(.vertical, TronSpacing.inputVertical)
            .frame(minHeight: 44)
            .glassEffect(
                .regular.tint(Color.tronEmerald.opacity(0.18)),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerInput, style: .continuous)
            )
    }
}

private struct TronTextEditorSurfaceModifier: ViewModifier {
    let monospaced: Bool

    func body(content: Content) -> some View {
        content
            .font(monospaced ? TronTypography.codeBlock : TronTypography.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
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

    func tronComposerField() -> some View {
        modifier(TronComposerFieldModifier())
    }

    /// Text input whose material is owned by a surrounding historical glass
    /// row/composer. This prevents nested field containers.
    func tronInlineField(composer: Bool = false, monospaced: Bool = false, numeric: Bool = false) -> some View {
        modifier(TronInlineFieldModifier(composer: composer, monospaced: monospaced, numeric: numeric))
    }

    func tronTextEditor(monospaced: Bool = false) -> some View {
        modifier(TronTextEditorSurfaceModifier(monospaced: monospaced))
    }
}

// MARK: - Read-only documents

enum TronReadOnlyTextStyle: Equatable, Sendable {
    case body
    case code
}

/// Native TextKit-backed document scrolling avoids asking SwiftUI to measure a
/// multi-hundred-kilobyte selectable `Text` before a sheet can present.
struct TronReadOnlyTextView: UIViewRepresentable {
    let text: String
    var style: TronReadOnlyTextStyle = .body
    var inset: CGFloat = 18

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
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
        let contentInset = UIEdgeInsets(
            top: inset,
            left: inset,
            bottom: max(24, inset),
            right: inset
        )
        if view.textContainerInset != contentInset {
            view.textContainerInset = contentInset
        }
    }
}

// MARK: - Search and selection controls

struct TronSearchBar: View {
    @Binding var text: String
    var prompt = "Search"
    var accent: Color = .tronEmerald
    var focusOnAppear = false
    var onClose: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
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

            if let onClose {
                Button {
                    focused = false
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .heavy))
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
    var minimumHeight: CGFloat = 44

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
                            .foregroundStyle(Color.tronAccentText)
                            .frame(maxWidth: .infinity, minHeight: minimumHeight)
                            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(accent.opacity(selected ? 0.28 : 0.08)).interactive(),
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

    var body: some View {
        TronTitleLabel(title: title, accent: accent)
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
    let onConfirm: () -> Void
    let onSecondary: (() -> Void)?
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
        icon: String = "exclamationmark.triangle.fill",
        onConfirm: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.destructive = destructive
        self.secondaryTitle = secondaryTitle
        self.centersTitle = centersTitle
        self.icon = icon
        self.onConfirm = onConfirm
        self.onSecondary = onSecondary
    }

    var body: some View {
        GeometryReader { geometry in
            let placement = TronConfirmationActionPlacementPolicy.placement(
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
                        .tronToolbarAction(accent: .tronTextSecondary)
                        .accessibilityIdentifier("confirmation-cancel")
                    }
                    if placement == .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            confirmButton
                                .tronToolbarAction(accent: accent)
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

struct TronSaveToolbarButton: View {
    let isSaving: Bool
    let isEnabled: Bool
    let action: () -> Void

    private var actionColor: Color {
        isEnabled && !isSaving ? .tronEmerald : .tronTextMuted
    }

    var body: some View {
        Button(action: action) {
            TronToolbarTextLabel(
                isSaving ? "Saving…" : "Save",
                systemImage: "square.and.arrow.down",
                isWorking: isSaving
            )
            .tronToolbarAction(accent: actionColor)
        }
        .tint(actionColor)
        .disabled(isSaving || !isEnabled)
        .accessibilityLabel(isSaving ? "Saving" : "Save")
        .accessibilityValue(isSaving ? "In progress" : isEnabled ? "Available" : "No changes")
    }
}

struct TronReloadToolbarButton: View {
    let isReloading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isReloading {
                TronPulseLoadingIndicator(size: 18)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronEmerald)
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
                accent: accent,
                cornerRadius: cornerRadius,
                tintOpacity: 0.14,
                interactive: interactive
            )
    }
}

enum TronSettingsGroupSurfaceStyle: Equatable, Sendable {
    case glass
    case scrollOptimized
}

struct TronSettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let detailRole: TronSettingsSecondaryRole
    let detailInline: Bool
    let accent: Color
    let surfaceStyle: TronSettingsGroupSurfaceStyle
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        detailRole: TronSettingsSecondaryRole = .informational,
        detailInline: Bool = false,
        accent: Color = .tronEmerald,
        surfaceStyle: TronSettingsGroupSurfaceStyle = .glass,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.detailRole = detailRole
        self.detailInline = detailInline
        self.accent = accent
        self.surfaceStyle = surfaceStyle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            if detailInline, let detail {
                HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
                    Text(title)
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: TronSpacing.sm)
                    Text(detail)
                        .font(detailRole.font)
                        .foregroundStyle(Color.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: TronSpacing.xs) {
                    Text(title)
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let detail {
                        Text(detail)
                            .font(detailRole.font)
                            .foregroundStyle(Color.tronTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            switch surfaceStyle {
            case .glass:
                TronGlassCard(accent: accent) { content }
            case .scrollOptimized:
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronScrollSurface(accent: accent, tintOpacity: 0.10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum TronSettingsSecondaryRole: Equatable, Sendable {
    /// Stable explanation or identity that does not change relative to its row.
    case informational
    /// Live state or a user-selectable setting value.
    case dynamicValue

    @MainActor var font: Font {
        switch self {
        case .informational: TronTypography.secondaryDescription
        case .dynamicValue: TronTypography.secondaryCodeDescription
        }
    }
}

struct TronSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let subtitleRole: TronSettingsSecondaryRole
    let subtitleLineLimit: Int?
    let accent: Color
    let titleColor: Color
    let subtitleColor: Color
    let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        subtitleRole: TronSettingsSecondaryRole = .informational,
        subtitleLineLimit: Int? = nil,
        accent: Color = .tronEmerald,
        titleColor: Color = .tronTextPrimary,
        subtitleColor: Color = .tronTextPrimary,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleRole = subtitleRole
        self.subtitleLineLimit = subtitleLineLimit
        self.accent = accent
        self.titleColor = titleColor
        self.subtitleColor = subtitleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleRole.font)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(subtitleLineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: subtitleLineLimit == nil)
                }
            }
            Spacer(minLength: TronSpacing.md)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, TronSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension TronSettingsRow where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        subtitleRole: TronSettingsSecondaryRole = .informational,
        subtitleLineLimit: Int? = nil,
        accent: Color = .tronEmerald,
        titleColor: Color = .tronTextPrimary,
        subtitleColor: Color = .tronTextPrimary
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            subtitleRole: subtitleRole,
            subtitleLineLimit: subtitleLineLimit,
            accent: accent,
            titleColor: titleColor,
            subtitleColor: subtitleColor
        ) { EmptyView() }
    }
}

struct TronInfoCard: View {
    let icon: String
    let text: String
    var accent: Color = .tronCyan

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(accent)
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
        .tronGlassSurface(accent: accent, tintOpacity: 0.09)
    }
}

struct TronSettingsDivider: View {
    var accent: Color = .tronEmerald
    var body: some View {
        Divider().overlay(accent.opacity(0.14)).padding(.leading, 52)
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

    static func secondaryRole(
        value: String?,
        placement: TronSettingsValuePlacement
    ) -> TronSettingsSecondaryRole {
        placement == .secondaryLine && value != nil ? .dynamicValue : .informational
    }
}

/// A live or user-selectable value. Values are always code-family and trailing
/// aligned when a row has no separate trailing control.
struct TronDynamicValue: View {
    let text: String
    var color: Color = .tronTextPrimary

    var body: some View {
        Text(text)
            .font(TronTypography.secondaryCodeDescription)
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

    private var secondaryRole: TronSettingsSecondaryRole {
        TronSettingsRowSemantics.secondaryRole(value: value, placement: valuePlacement)
    }

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondaryText, !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(secondaryRole.font)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TronSpacing.md)
            if valuePlacement == .trailing, let value, !value.isEmpty {
                TronDynamicValue(text: value)
                    .layoutPriority(1)
            }
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
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

private struct TronToggleControl: View {
    let isOn: Bool
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(accent.opacity(isOn ? 0.28 : 0.08))
            Circle()
                .fill(isOn ? accent : Color.tronTextMuted)
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
    @Binding var isOn: Bool

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        accent: Color = .tronEmerald,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accent = accent
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            TronValueRow(icon: icon, title: title, detail: detail, accent: accent) {
                TronToggleControl(isOn: isOn, accent: accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { Text(title) }
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
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .glassEffect(.regular.tint(accent.opacity(0.10)).interactive(), in: Capsule())
        }
        .accessibilityLabel(title)
    }
}

struct TronSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(
                            .regular.tint(Color.tronEmerald.opacity(0.10)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                )
                .listRowSeparator(.hidden)
        } header: {
            TronSectionHeader(title)
        }
    }
}

struct TronSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .bold))
            .foregroundStyle(Color.tronTextPrimary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
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

/// A dependency-free, concentric pulse inspired by the requested loading
/// treatment. One Canvas draws all three waves; TimelineView supplies a
/// lifecycle-bound clock without retaining per-indicator animation tasks.
enum TronPulseLoadingIndicatorEngine {
    static let pulseCount = 3
    static let cycleDuration = 1.6

    static func animationPaused(reduceMotion: Bool, sceneActive: Bool) -> Bool {
        reduceMotion || !sceneActive
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

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: TronPulseLoadingIndicatorEngine.animationPaused(
                reduceMotion: reduceMotion,
                sceneActive: scenePhase == .active
            )
        )) { _ in
            Canvas { context, canvasSize in
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
                        with: .color(accent.opacity(0.72))
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
                            with: .color(accent.opacity(
                                TronPulseLoadingIndicatorEngine.opacity(progress: progress)
                            ))
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TronLoadingState: View {
    let label: String
    var accent: Color = .tronEmerald

    var body: some View {
        HStack(spacing: TronSpacing.md) {
            TronPulseLoadingIndicator(accent: accent)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(Color.tronTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
