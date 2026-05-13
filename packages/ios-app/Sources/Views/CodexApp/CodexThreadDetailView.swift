import SwiftUI

@available(iOS 26.0, *)
struct CodexThreadDetailView: View {
    let viewModel: CodexAppViewModel

    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var transcriptContentHeight = 0
    @State private var isPrependingHistory = false

    private var accent: Color { .tronInfo }
    private var title: String {
        viewModel.state.selectedThread?.title ?? (viewModel.state.isDraftingNewThread ? "New Codex Thread" : "Codex")
    }

    private var scrollFingerprint: String {
        let last = viewModel.state.entries.last
        let lastMessage = viewModel.state.messages.last
        return [
            viewModel.state.selectedThreadId ?? "draft",
            "\(viewModel.state.entries.count)",
            last?.id ?? "",
            "\(lastMessage?.streamingVersion ?? 0)",
            "\(viewModel.state.pendingApprovals.count)"
        ].joined(separator: ":")
    }

    private var initialScrollFingerprint: String {
        [
            viewModel.state.selectedThreadId ?? "draft",
            viewModel.state.entries.first?.id ?? "",
            viewModel.state.entries.last?.id ?? "",
            "\(viewModel.state.entries.count)"
        ].joined(separator: ":")
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingThread && viewModel.state.entries.isEmpty {
                loadingState
            } else if viewModel.state.selectedThreadId == nil && viewModel.state.entries.isEmpty {
                emptyState
            } else {
                transcript
            }

            CodexComposerBar(
                text: $inputText,
                isRunning: viewModel.state.isTurnRunning,
                isConnected: viewModel.connectionState.isConnected,
                onSend: send,
                onInterrupt: {
                    Task { try? await viewModel.interrupt() }
                }
            )
        }
        .tronScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(TronTypography.sans(size: 20, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
        }
        .onChange(of: scrollFingerprint) { _, _ in
            guard !isPrependingHistory else { return }
            scrollToBottom(animated: true)
        }
        .task(id: initialScrollFingerprint) {
            guard !isPrependingHistory else { return }
            try? await Task.sleep(for: .milliseconds(80))
            await settleScrollToBottom(animated: false)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(accent)
            Text("Loading Codex thread")
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(accent)
            Text("Start a Codex thread")
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -30)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.hasEarlierThreadEntries {
                        loadEarlierButton
                            .id("codex-load-earlier")
                    }

                    ForEach(viewModel.state.entries) { entry in
                        switch entry {
                        case .message(let message):
                            MessageBubble(message: message)
                                .id(entry.id)
                        case .item(let item):
                            CodexItemRow(item: item)
                                .id(entry.id)
                        }
                    }

                    ForEach(viewModel.state.pendingApprovals) { approval in
                        CodexApprovalCard(approval: approval) { decision in
                            Task { try? await viewModel.resolveApproval(approval, decision: decision) }
                        }
                    }

                    if let error = viewModel.state.errorMessage {
                        MessageBubble(message: ChatMessage(role: .system, content: .error(error)))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("codex-bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int(geometry.contentSize.height)
            } action: { _, height in
                transcriptContentHeight = height
            }
            .onAppear {
                scrollProxy = proxy
                Task { await settleScrollToBottom(animated: false) }
            }
        }
    }

    private var loadEarlierButton: some View {
        Button {
            loadEarlierEntries()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoadingEarlierThreadEntries {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.tronTextMuted)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                Text(viewModel.isLoadingEarlierThreadEntries ? "Loading..." : "Load Earlier Entries")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(.tronTextSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.tronOverlay(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingEarlierThreadEntries)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let text = inputText
        inputText = ""
        Task {
            do {
                try await viewModel.sendText(text)
            } catch {
                viewModel.state.errorMessage = error.localizedDescription
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard let scrollProxy else { return }
        if animated {
            withAnimation(.smooth(duration: 0.22)) {
                scrollProxy.scrollTo("codex-bottom", anchor: .bottom)
            }
        } else {
            scrollProxy.scrollTo("codex-bottom", anchor: .bottom)
        }
    }

    @MainActor
    private func settleScrollToBottom(animated: Bool) async {
        guard scrollProxy != nil else { return }
        for index in 0..<8 {
            let before = transcriptContentHeight
            scrollToBottom(animated: animated && index == 0)
            try? await Task.sleep(for: .milliseconds(30))
            let after = transcriptContentHeight
            if after == before && index >= 1 {
                break
            }
        }
        scrollToBottom(animated: animated)
    }

    private func loadEarlierEntries() {
        guard !isPrependingHistory else { return }
        let firstVisibleEntryId = viewModel.state.entries.first?.id
        isPrependingHistory = true

        Task { @MainActor in
            await viewModel.loadEarlierThreadEntries()
            try? await Task.sleep(for: .milliseconds(50))
            if let firstVisibleEntryId {
                scrollProxy?.scrollTo(firstVisibleEntryId, anchor: .top)
            } else {
                scrollProxy?.scrollTo("codex-bottom", anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(50))
            isPrependingHistory = false
        }
    }
}

@available(iOS 26.0, *)
private struct CodexComposerBar: View {
    @Binding var text: String
    let isRunning: Bool
    let isConnected: Bool
    let onSend: () -> Void
    let onInterrupt: () -> Void

    private var canSend: Bool {
        isConnected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message Codex", text: $text, axis: .vertical)
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassEffect(.regular.tint(Color.tronInfo.opacity(0.14)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .disabled(!isConnected)

            Button {
                if isRunning {
                    onInterrupt()
                } else {
                    onSend()
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .disabled(isRunning ? false : !canSend)
            .glassEffect(.regular.tint(Color.tronInfo.opacity(canSend || isRunning ? 0.75 : 0.25)).interactive(), in: .circle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

@available(iOS 26.0, *)
private struct CodexItemRow: View {
    let item: CodexAppItem

    private var icon: String {
        switch item {
        case .agentMessage: "text.bubble"
        case .reasoning: "brain"
        case .command: "terminal"
        case .fileChange: "doc.text"
        case .pluginCapability: "point.3.connected.trianglepath.dotted"
        case .webSearch: "magnifyingglass"
        case .plan: "checklist"
        case .diff: "doc.text.magnifyingglass"
        case .other: "circle.hexagongrid"
        }
    }

    private var title: String {
        switch item {
        case .agentMessage: "Assistant"
        case .reasoning: "Reasoning"
        case .command(_, let command, _, let status, _): "\(status): \(command)"
        case .fileChange(_, let status, _): "File change \(status)"
        case .pluginCapability(_, let source, let capability, let status, _): "\(source ?? "Plugin source") \(capability ?? "capability") \(status)"
        case .webSearch(_, let query, let status): "Search \(status): \(query ?? "")"
        case .plan: "Plan"
        case .diff: "Diff"
        case .other(_, let title, _): title
        }
    }

    private var detail: String? {
        switch item {
        case .agentMessage(_, let text),
             .reasoning(_, let text, _),
             .plan(_, let text),
             .diff(_, let text):
            text
        case .command(_, _, let cwd, _, let output):
            [cwd, output].compactMap { $0 }.joined(separator: "\n").nilIfBlank
        case .fileChange(_, _, let summary),
             .pluginCapability(_, _, _, _, let summary),
             .other(_, _, let summary):
            summary
        case .webSearch:
            nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronInfo)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .sectionFill(.tronInfo, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@available(iOS 26.0, *)
private struct CodexApprovalCard: View {
    let approval: CodexApprovalRequest
    let onDecision: (CodexApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.tronWarning)
                Text(approval.kind == .command ? "Command approval" : "File approval")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Spacer()
            }

            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }

            HStack(spacing: 8) {
                Button("Allow") { onDecision(.accept) }
                Button("Session") { onDecision(.acceptForSession) }
                Button("Deny") { onDecision(.decline) }
                Button("Cancel") { onDecision(.cancel) }
            }
            .buttonStyle(.bordered)
            .tint(.tronWarning)
        }
        .padding(12)
        .sectionFill(.tronWarning, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
