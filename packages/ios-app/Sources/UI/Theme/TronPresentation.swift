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

    func tronToolbarAction(accent: Color = .tronEmerald) -> some View {
        font(TronTypography.buttonSM)
            .foregroundStyle(accent)
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
                    ProgressView().controlSize(.small).tint(accent).accessibilityHidden(true)
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

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? TronTypography.code(size: TronTypography.sizeBody) : TronTypography.input)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(Color.tronEmerald)
            .padding(.horizontal, compact ? TronSpacing.md : TronSpacing.section)
            .padding(.vertical, compact ? TronSpacing.sm : TronSpacing.md)
            .frame(minHeight: 52)
            .glassEffect(
                .regular.tint(Color.tronSurfaceElevated.opacity(0.34)),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .stroke(Color.tronBorder.opacity(0.55), lineWidth: 0.5)
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
    func tronField(monospaced: Bool = false, compact: Bool = false) -> some View {
        modifier(TronFieldSurfaceModifier(monospaced: monospaced, compact: compact))
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

// MARK: - Search and selection controls

struct TronSearchBar: View {
    @Binding var text: String
    var prompt = "Search"
    var accent: Color = .tronEmerald
    var focusOnAppear = false
    var onClose: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: TronSpacing.lg) {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(accent.opacity(0.68)))
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
            .glassEffect(.clear.tint(accent.opacity(0.10)).interactive(), in: .capsule)
            .contentShape(Capsule())
            .onTapGesture { focused = true }

            if let onClose {
                Button {
                    focused = false
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glassEffect(.clear.tint(accent.opacity(0.10)).interactive(), in: .circle)
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
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}


struct TronSegmentedControl<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var accent: Color = .tronEmerald

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
                            .frame(maxWidth: .infinity, minHeight: 44)
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

struct TronConfirmationSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    let secondaryTitle: String?
    let onConfirm: () -> Void
    let onSecondary: (() -> Void)?
    let icon: String

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false,
        secondaryTitle: String? = nil,
        icon: String = "exclamationmark.triangle.fill",
        onConfirm: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.destructive = destructive
        self.secondaryTitle = secondaryTitle
        self.icon = icon
        self.onConfirm = onConfirm
        self.onSecondary = onSecondary
    }

    var body: some View {
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
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
                .padding(24)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Confirm", accent: .tronEmerald)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(secondaryTitle ?? "Cancel") {
                        dismiss()
                        onSecondary?()
                    }
                    .tronToolbarAction(accent: .tronTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle, role: destructive ? .destructive : nil) {
                        dismiss()
                        onConfirm()
                    }
                    .tronToolbarAction(accent: accent)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var accent: Color { destructive ? .tronError : .tronEmerald }
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
            HStack(spacing: 5) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(actionColor)
                }
                Text(isSaving ? "Saving…" : "Save")
            }
            .tronToolbarAction()
            .foregroundStyle(actionColor)
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
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.tronEmerald)
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

struct TronSettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let accent: Color
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        accent: Color = .tronEmerald,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(title)
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TronGlassCard(accent: accent) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TronSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let accent: Color
    let titleColor: Color
    let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        accent: Color = .tronEmerald,
        titleColor: Color = .tronTextPrimary,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.titleColor = titleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .regular))
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TronSpacing.md)
            trailing
        }
        .padding(.horizontal, TronSpacing.xl)
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
        accent: Color = .tronEmerald,
        titleColor: Color = .tronTextPrimary
    ) {
        self.init(icon: icon, title: title, subtitle: subtitle, accent: accent, titleColor: titleColor) { EmptyView() }
    }
}

struct TronSettingsDivider: View {
    var accent: Color = .tronEmerald
    var body: some View {
        Divider().overlay(accent.opacity(0.14)).padding(.leading, 52)
    }
}

struct TronValueRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let accent: Color
    let trailing: Trailing

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        accent: Color = .tronEmerald,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accent = accent
        self.trailing = trailing()
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
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TronSpacing.md)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension TronValueRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil, accent: Color = .tronEmerald) {
        self.init(icon: icon, title: title, detail: detail, accent: accent) { EmptyView() }
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
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(accent.opacity(isOn ? 0.28 : 0.08))
                    Circle()
                        .fill(isOn ? accent : Color.tronTextMuted)
                        .padding(4)
                }
                .frame(width: 50, height: 30)
                .glassEffect(.regular.tint(accent.opacity(isOn ? 0.14 : 0.05)), in: Capsule())
                .animation(.snappy(duration: 0.18), value: isOn)
                .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
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

struct TronLoadingState: View {
    let label: String
    var accent: Color = .tronEmerald

    var body: some View {
        HStack(spacing: TronSpacing.md) {
            ProgressView().controlSize(.small).tint(accent).accessibilityHidden(true)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(Color.tronTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
