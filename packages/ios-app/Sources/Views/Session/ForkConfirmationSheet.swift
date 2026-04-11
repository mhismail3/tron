import SwiftUI

// MARK: - Fork Confirmation Sheet

/// Confirmation sheet for forking a session from a specific event
@available(iOS 26.0, *)
struct ForkConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let eventId: String
    let event: SessionEvent?
    let sessionId: String
    let eventStoreManager: EventStoreManager
    let onDismissParent: () -> Void

    @State private var isForking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "tuningfork")
                    .font(TronTypography.sans(size: 44, weight: .light))
                    .foregroundStyle(.tronPurple)
                    .frame(width: 72, height: 72)
                    .background {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: Circle())
                    }

                VStack(spacing: 8) {
                    Text("Fork Session")
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Text("Create a new branch from this point")
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextMuted)

                    if let event = event {
                        HStack(spacing: 6) {
                            Image(systemName: "quote.opening")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronPurple.opacity(0.5))

                            Text(event.summary)
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.tronTextSecondary)
                                .lineLimit(2)

                            Image(systemName: "quote.closing")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronPurple.opacity(0.5))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.tronPurple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 8)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    .disabled(isForking)
                }
                ToolbarItem(placement: .principal) {
                    Text("Fork Session")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await performFork() }
                    } label: {
                        if isForking {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.tronPurple)
                        } else {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronPurple)
                        }
                    }
                    .disabled(isForking)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronPurple)
    }

    private func performFork() async {
        isForking = true
        logger.debug("Fork initiated: sessionId=\(sessionId), fromEventId=\(eventId)", category: .session)

        do {
            let newSessionId = try await eventStoreManager.forkSession(sessionId, fromEventId: eventId)
            logger.debug("Fork succeeded: newSessionId=\(newSessionId)", category: .session)
            eventStoreManager.setActiveSession(newSessionId)
            eventStoreManager.loadSessions()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
            dismiss()
            onDismissParent()
        } catch {
            logger.error("Fork FAILED: \(error)", category: .session)
            isForking = false
        }
    }
}
