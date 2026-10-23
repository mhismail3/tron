import SwiftUI

/// Why a retained transcript is not live. `ChatView.retainedRecoveryStatus`
/// is its only producer; transient app notices never own this state.
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

/// A one-line recovery capsule in the chat title's place in the navigation
/// chrome. The whole capsule is the Retry control, so its touch target is the
/// visible glass rather than one small word. Liquid Glass matches the bar's own
/// back and settings controls and keeps the line legible over the scrolled
/// transcript. VoiceOver reads the reason, its full explanation, then Retry.
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
        // Like the system bar items beside it, the fixed-height bar stops
        // growing at the largest standard size; the large content viewer and
        // the VoiceOver value carry the reason beyond it.
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
