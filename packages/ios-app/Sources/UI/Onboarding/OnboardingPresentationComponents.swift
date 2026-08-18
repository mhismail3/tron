import SwiftUI

struct OnboardingNavigationTitle: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        let base = TronFontLoader.createUIFont(size: 16, weight: .semibold)
        label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: base)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? "#34D399" : "#047857")
        }
        label.accessibilityTraits.insert(.header)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: min(proposal.width ?? intrinsic.width, intrinsic.width), height: intrinsic.height)
    }
}

struct PairingCodeField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.placeholder = "One-time code"
        field.accessibilityLabel = "One-time code"
        field.isSecureTextEntry = true
        field.textContentType = .oneTimeCode
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        let base = TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular, mono: true)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var text: String
        init(text: Binding<String>) { _text = text }
        @objc func changed(_ sender: UITextField) { text = sender.text ?? "" }
    }
}

struct OnboardingPage<Content: View>: View {
    let subtitle: String
    @ViewBuilder let content: Content
    init(subtitle: String, @ViewBuilder content: () -> Content) { self.subtitle = subtitle; self.content = content() }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                Text(subtitle)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 126)
            .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tronEmerald.opacity(0.22), lineWidth: 1))
    }
}

struct OnboardingInfoRow: View {
    let icon, title, subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronEmerald).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
