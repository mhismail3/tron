import SwiftUI

// MARK: - Session History Sheet

/// Sheet for viewing and interacting with session history tree
@available(iOS 26.0, *)
struct SessionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let sessionId: String
    let rpcClient: RPCClient
    let eventStoreManager: EventStoreManager

    @State private var viewModel: SessionHistoryViewModel
    @State private var forkEventId: String?

    init(sessionId: String, rpcClient: RPCClient, eventStoreManager: EventStoreManager) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        self.eventStoreManager = eventStoreManager
        self._viewModel = State(initialValue: SessionHistoryViewModel(
            sessionId: sessionId,
            eventStoreManager: eventStoreManager,
            rpcClient: rpcClient
        ))
    }

    var body: some View {
        NavigationStack {
            SessionHistoryView(
                events: viewModel.events,
                headEventId: viewModel.headEventId,
                sessionId: sessionId,
                forkContext: viewModel.forkContext,
                onFork: { eventId in
                    forkEventId = eventId
                },
                isLoading: viewModel.isLoading
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session History")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronPurple)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronPurple)
        .preferredColorScheme(.dark)
        .task {
            await viewModel.loadEvents()
        }
        .sheet(item: Binding(
            get: { forkEventId.map { ForkEventWrapper(eventId: $0) } },
            set: { forkEventId = $0?.eventId }
        )) { wrapper in
            ForkConfirmationSheet(
                eventId: wrapper.eventId,
                event: viewModel.events.first(where: { $0.id == wrapper.eventId }),
                sessionId: sessionId,
                eventStoreManager: eventStoreManager,
                onDismissParent: { dismiss() }
            )
        }
    }
}

/// Wrapper to make eventId identifiable for sheet presentation
private struct ForkEventWrapper: Identifiable {
    let eventId: String
    var id: String { eventId }
}

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
            // Centered content
            VStack(spacing: 20) {
                Spacer()

                // Icon
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: 44, weight: .light))
                    .foregroundStyle(.tronPurple)
                    .frame(width: 72, height: 72)
                    .background {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: Circle())
                    }

                // Title and description
                VStack(spacing: 8) {
                    Text("Fork Session")
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Text("Create a new branch from this point")
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextMuted)

                    // Show the fork point summary
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
                    Button {
                        dismiss()
                    } label: {
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
                        Task {
                            await performFork()
                        }
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
        .preferredColorScheme(.dark)
    }

    private func performFork() async {
        isForking = true
        logger.debug("Fork initiated: sessionId=\(sessionId), fromEventId=\(eventId)", category: .session)
        if let event = event {
            logger.debug("Fork point: type=\(event.type), sequence=\(event.sequence)", category: .session)
        }

        do {
            let newSessionId = try await eventStoreManager.forkSession(sessionId, fromEventId: eventId)
            logger.debug("Fork succeeded: newSessionId=\(newSessionId)", category: .session)
            eventStoreManager.setActiveSession(newSessionId)
            dismiss()
            onDismissParent()
        } catch {
            logger.error("Fork FAILED: \(error)", category: .session)
            isForking = false
        }
    }
}
