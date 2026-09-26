import SwiftUI

/// Portrait (3:4) label for one model in the picker's Recent and Latest rails.
/// `TronCardRail` owns the glass surface and press behavior; this view owns
/// only the card's content. Facts come straight from the Gateway catalog, and
/// an absent fact is omitted rather than shown as zero.
struct ModelRailCard: View {
    let model: ModelSummary
    /// Non-nil paints the selected checkmark in that accent.
    let selectionAccent: Color?

    static let width: CGFloat = 138
    /// A minimum, so larger Dynamic Type grows the card instead of clipping it.
    static let minimumHeight: CGFloat = width * 4 / 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.displayProviderName)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let selectionAccent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(selectionAccent)
                }
            }
            Text(model.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 6) {
                if let context = ModelCardFacts.contextLabel(model.contextWindow) {
                    fact(value: context, caption: "Context")
                }
                if let price = ModelCardFacts.priceLabel(model.cost) {
                    fact(value: price, caption: "In / out per 1M")
                }
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(minHeight: Self.minimumHeight, alignment: .topLeading)
    }

    private func fact(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
        }
    }

    static func accessibilityLabel(_ model: ModelSummary) -> String {
        var parts = [model.displayName, model.displayProviderName]
        if let context = ModelCardFacts.contextLabel(model.contextWindow) {
            parts.append("\(context) token context")
        }
        if let cost = model.cost, let price = ModelCardFacts.priceLabel(cost) {
            let halves = price.components(separatedBy: " / ")
            parts.append("\(halves.first ?? price) input, \(halves.last ?? price) output per million tokens")
        }
        return parts.joined(separator: ", ")
    }
}
