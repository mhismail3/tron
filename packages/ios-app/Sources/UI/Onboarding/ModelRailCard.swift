import SwiftUI

/// Portrait label for one model in the picker's Recent and Latest rails.
/// `TronCardRail` owns the glass surface and press behavior; this view owns
/// only the card's content. Facts come straight from the Gateway catalog, and
/// an absent fact is omitted rather than shown as zero.
struct ModelRailCard: View {
    let model: ModelSummary
    /// Non-nil paints the selected checkmark in that accent.
    let selectionAccent: Color?

    static let width: CGFloat = 138
    /// A minimum, so larger Dynamic Type grows the card instead of clipping it.
    /// Sized so both rails fit a medium-detent Manage Session sheet.
    static let minimumHeight: CGFloat = 138
    private static let checkmarkSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.displayProviderName)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
                // Room for the overlaid checkmark, reserved in both states.
                .padding(.trailing, Self.checkmarkSize + 4)
            Text(model.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 3) {
                if let context = ModelCardFacts.contextLabel(model.contextWindow) {
                    (Text(context)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    + Text(" context")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextSecondary))
                        .lineLimit(1)
                }
                if let price = ModelCardFacts.priceLabel(model.cost) {
                    fact(value: price, caption: "In / out per 1M")
                }
                if let released = ModelCardFacts.releaseLabel(model.releaseDate) {
                    Text(released)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(minHeight: Self.minimumHeight, alignment: .topLeading)
        // An overlay never participates in layout, so selecting a card cannot
        // move its name or facts (`ModelRailCardLayoutTests`).
        .overlay(alignment: .topTrailing) {
            if let selectionAccent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Self.checkmarkSize, weight: .semibold))
                    .foregroundStyle(selectionAccent)
                    .padding([.top, .trailing], 8)
            }
        }
    }

    private func fact(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
        if let released = ModelCardFacts.releaseLabel(model.releaseDate) {
            parts.append("released \(released)")
        }
        return parts.joined(separator: ", ")
    }
}
