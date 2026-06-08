import SwiftUI

// MARK: - Classified Error Section

/// Shared error section that uses `ErrorClassification` to render structured error UI.
/// Replaces duplicated error section patterns across generated capability sheets.
struct CapabilityClassifiedErrorSection<AdditionalContent: View>: View {
    let errorMessage: String
    let classification: ErrorClassification
    let colorScheme: ColorScheme
    @ViewBuilder let additionalContent: () -> AdditionalContent

    var body: some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        CapabilityDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: classification.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronError)

                    Text(classification.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                additionalContent()

                if let code = classification.code {
                    CapabilityInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
                }

                Text(classification.suggestion)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
            }
        }
    }
}

extension CapabilityClassifiedErrorSection where AdditionalContent == EmptyView {
    init(errorMessage: String, classification: ErrorClassification, colorScheme: ColorScheme) {
        self.errorMessage = errorMessage
        self.classification = classification
        self.colorScheme = colorScheme
        self.additionalContent = { EmptyView() }
    }
}
