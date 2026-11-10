import SwiftUI

enum ChatRetainedRecoveryStatus: Equatable {
    case waitingForConnection
    case unavailable(String)

    var title: String {
        switch self {
        case .waitingForConnection: "Waiting for connection"
        case .unavailable: "Conversation unavailable"
        }
    }

    var message: String {
        switch self {
        case .waitingForConnection: "This conversation will resume when the Mac reconnects."
        case .unavailable(let message): message
        }
    }

    var tone: ChatNotificationTone {
        switch self {
        case .waitingForConnection: .warning
        case .unavailable: .error
        }
    }
}

struct ChatRecoveryStatusLine: View {
    let status: ChatRetainedRecoveryStatus
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                    Text(status.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(status.tone.primaryColor)
                Text("Retry")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.tronPrimary)
                    .fixedSize()
            }
            .font(TronTypography.bodySM)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer {
            Label(status.title, systemImage: "exclamationmark.triangle.fill")
        }
        .accessibilityLabel(status.title)
        .accessibilityValue(status.message)
        .accessibilityHint("Retries the connection")
        .accessibilityIdentifier("chat-recovery-status")
    }
}
