import SwiftUI

// MARK: - Error View

/// Structured error display with icon, title, path, error code badge, and suggestion
@available(iOS 26.0, *)
struct ToolErrorView: View {
    let icon: String
    let title: String
    let path: String
    let errorCode: String?
    let suggestion: String
    var tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeXL))
                    .foregroundStyle(.tronError)

                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronError)
            }

            if !path.isEmpty {
                Text(path)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(tint.secondary)
                    .textSelection(.enabled)
            }

            if let code = errorCode {
                ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
            }

            Text(suggestion)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.subtle)
        }
    }
}
