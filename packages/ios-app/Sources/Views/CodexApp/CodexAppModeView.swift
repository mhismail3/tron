import SwiftUI

@available(iOS 26.0, *)
enum CodexAppModeContent: Equatable {
    case noActiveServerSetup
    case dashboard
}

@available(iOS 26.0, *)
enum CodexAppModePresentation {
    static func content(
        activeServer: PairedServer?,
        serverStatus: CodexAppServerStatusResult?,
        activeEndpoint: CodexAppEndpoint?
    ) -> CodexAppModeContent {
        guard activeServer != nil else { return .noActiveServerSetup }
        return .dashboard
    }
}

@available(iOS 26.0, *)
struct CodexAppModeView: View {
    let viewModel: CodexAppViewModel
    let activeServer: PairedServer?
    let activeServerSelectionVersion: Int
    let actions: DashboardToolbarActions

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var compactPath: [CodexRoute] = []

    private var accent: Color { .tronInfo }

    private var content: CodexAppModeContent {
        CodexAppModePresentation.content(
            activeServer: activeServer,
            serverStatus: viewModel.serverStatus,
            activeEndpoint: viewModel.activeEndpoint
        )
    }

    var body: some View {
        Group {
            if content == .noActiveServerSetup {
                setupContent
            } else if horizontalSizeClass == .compact {
                compactContent
            } else {
                regularContent
            }
        }
        .tronScreenBackground()
        .tint(accent)
        .onAppear {
            configureViewModel()
        }
        .onChange(of: activeServerSelectionVersion) { _, _ in
            compactPath.removeAll()
            configureViewModel()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase != .active, newPhase == .active else { return }
            Task { await viewModel.recoverForeground() }
        }
        .task(id: activeServerSelectionVersion) {
            await viewModel.runDashboardAutoRefresh()
        }
    }

    private func configureViewModel() {
        let client = dependencies.rpcClient
        viewModel.configure(
            activeServer: activeServer,
            serverStatusProvider: { try await client.codexAppServer.status() }
        )
    }

    private var setupContent: some View {
        NavigationStack {
            CodexAppSetupView(
                viewModel: viewModel,
                activeServer: activeServer,
                onDone: {}
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                DashboardToolbarContent(title: "Codex", accent: accent, actions: actions)
            }
        }
    }

    private var compactContent: some View {
        NavigationStack(path: $compactPath) {
            CodexThreadDashboard(
                viewModel: viewModel,
                activeServer: activeServer,
                actions: actions,
                onOpenThread: openThread,
                onNewThread: newThread
            )
            .navigationDestination(for: CodexRoute.self) { _ in
                CodexThreadDetailView(viewModel: viewModel)
            }
        }
    }

    private var regularContent: some View {
        NavigationSplitView {
            CodexThreadDashboard(
                viewModel: viewModel,
                activeServer: activeServer,
                actions: actions,
                onOpenThread: { threadId in
                    Task { try? await viewModel.openThread(threadId) }
                },
                onNewThread: {
                    viewModel.prepareNewThread()
                }
            )
            .frame(minWidth: 300)
        } detail: {
            if viewModel.state.selectedThreadId != nil || viewModel.state.isDraftingNewThread {
                CodexThreadDetailView(viewModel: viewModel)
            } else {
                CodexSelectThreadPrompt(onNewThread: {
                    viewModel.prepareNewThread()
                })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .scrollContentBackground(.hidden)
    }

    private func openThread(_ threadId: String) {
        compactPath.append(.thread(threadId))
        Task { try? await viewModel.openThread(threadId) }
    }

    private func newThread() {
        viewModel.prepareNewThread()
        compactPath.append(.newThread)
    }
}

@available(iOS 26.0, *)
private enum CodexRoute: Hashable {
    case thread(String)
    case newThread
}

@available(iOS 26.0, *)
private struct CodexThreadDashboard: View {
    let viewModel: CodexAppViewModel
    let activeServer: PairedServer?
    let actions: DashboardToolbarActions
    let onOpenThread: (String) -> Void
    let onNewThread: () -> Void

    private var accent: Color { .tronInfo }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                serverHeader
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                List {
                    Section {
                        ForEach(viewModel.state.threads) { thread in
                            Button {
                                onOpenThread(thread.id)
                            } label: {
                                CodexThreadRow(
                                    thread: thread,
                                    isSelected: thread.id == viewModel.state.selectedThreadId
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task { try? await viewModel.archiveThread(thread.id) }
                                } label: {
                                    Image(systemName: "archivebox")
                                }
                                .tint(accent)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 4)
                .refreshable {
                    await viewModel.refreshDashboard()
                }
                .overlay {
                    dashboardOverlay
                }
            }

            FloatingNewSessionButton(action: onNewThread, size: 56, accent: accent)
                .disabled(!canCreateThread)
                .opacity(canCreateThread ? 1 : 0.4)
                .padding(.trailing, 20)
                .padding(.bottom, 8)
        }
        .tronScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            DashboardToolbarContent(title: "Codex", accent: accent, actions: actions)
        }
    }

    private var canCreateThread: Bool {
        viewModel.connectionState.isConnected
    }

    private var connectionIssueMessage: String? {
        if viewModel.connectionState.isConnected {
            return nil
        }
        if let status = viewModel.serverStatus {
            if !status.enabled {
                return "Codex App Server is disabled in Tron Server settings."
            }
            if !status.isRunning {
                return status.lastError ?? "Codex App Server is \(status.state)."
            }
        }
        switch viewModel.connectionState {
        case .failed(let reason), .unauthorized(let reason):
            return reason
        default:
            return nil
        }
    }

    private var serverHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(activeServer?.label ?? "No Server")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Text(headerSubtitle)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            if viewModel.isLoadingThreads {
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            }
        }
    }

    private var headerSubtitle: String {
        if let endpoint = viewModel.activeEndpoint {
            return endpoint.url.absoluteString
        }
        if let status = viewModel.serverStatus {
            return status.lastError ?? "Codex App Server is \(status.state)"
        }
        return "Connecting"
    }

    @ViewBuilder
    private var dashboardOverlay: some View {
        if viewModel.isRefreshingDashboard && viewModel.state.threads.isEmpty {
            ProgressView()
                .controlSize(.large)
                .tint(accent)
                .allowsHitTesting(false)
        } else if let issue = connectionIssueMessage, viewModel.state.threads.isEmpty {
            CodexDashboardConnectionIssue(
                message: issue,
                isRetrying: viewModel.isRefreshingDashboard,
                onRetry: {
                    Task { await viewModel.refreshDashboard() }
                }
            )
            .padding(.horizontal, 24)
            .offset(y: -44)
        } else if viewModel.state.threads.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(accent)

                Text("No Codex threads")
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.tronTextMuted)
            }
            .offset(y: -50)
            .allowsHitTesting(false)
        }
    }
}

@available(iOS 26.0, *)
private struct CodexDashboardConnectionIssue: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    private var accent: Color { .tronInfo }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tronWarning)

            VStack(spacing: 6) {
                Text("Codex Server Unavailable")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }

            Button(action: onRetry) {
                Label(isRetrying ? "Checking" : "Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(isRetrying)
        }
        .padding(18)
        .frame(maxWidth: 420)
        .sectionFill(.tronInfo, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@available(iOS 26.0, *)
private struct CodexSelectThreadPrompt: View {
    let onNewThread: () -> Void

    private var accent: Color { .tronInfo }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(accent)

                    Text("Choose a Codex thread")
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -60)

                FloatingNewSessionButton(action: onNewThread, accent: accent)
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
            }
            .tronScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Codex")
                        .font(TronTypography.sans(size: 20, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct CodexThreadRow: View {
    let thread: CodexThreadSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: thread.status == .running ? "play.circle.fill" : "terminal")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronInfo)
                Text(thread.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                Spacer()
            }

            if let cwd = thread.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sectionFill(.tronInfo, subtle: !isSelected, interactive: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
