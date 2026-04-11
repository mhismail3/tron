import SwiftUI

// MARK: - Session ID Row

/// Displays the session ID with a copy-to-clipboard gesture.
/// Extracted from ContextAnalyticsOverview for shared use.
@available(iOS 26.0, *)
struct SessionIdRow: View {
    let sessionId: String
    @State private var showCopied = false

    var body: some View {
        HStack {
            Image(systemName: "number.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronAmber)

            Text(showCopied ? "Copied!" : sessionId)
                .font(TronTypography.codeCaption)
                .foregroundStyle(showCopied ? .tronEmerald : .tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopied)

            Spacer()

            Image(systemName: "doc.on.doc")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(12)
        .sectionFill(.tronAmber)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            UIPasteboard.general.string = sessionId
            showCopied = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                showCopied = false
            }
        }
    }
}
