import SwiftUI

/// Shared field/type hierarchy for parsed JSON shown in detail sheets.
///
/// Field identity stays on the leading edge, while the value type remains
/// consistently trailing metadata. Values and previews belong below this
/// header so scalar and collection rows scan the same way.
struct StructuredDataFieldHeader: View {
    let title: String
    let type: String
    var qualifier: String?
    var titleIsCode = false
    var typeColor: Color = .tronTextMuted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(
                    titleIsCode
                        ? TronTypography.code(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        )
                        : TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        )
                )
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            if let qualifier, !qualifier.isEmpty {
                Text(qualifier)
                    .font(
                        TronTypography.sans(
                            size: TronTypography.sizeSM,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.tronWarning)
                    .lineLimit(1)
            }

            Text(type)
                .font(
                    TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .medium
                    )
                )
                .foregroundStyle(typeColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
