import SwiftUI

@available(iOS 26.0, *)
struct SandboxesDashboardView: View {
    let rpcClient: RPCClient
    let onSettings: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?

    @State private var containers: [ContainerDTO] = []
    @State private var tailscaleIp: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedContainer: ContainerDTO?
    @State private var safariURL: URL?

    @State private var containerAction: ContainerAction?
    @State private var showKillConfirmation = false
    @State private var actionInProgress: String?
    @State private var actionError: String?

    private enum ContainerAction {
        case kill(ContainerDTO)
        case stop(ContainerDTO)
        case start(ContainerDTO)

        var container: ContainerDTO {
            switch self {
            case .kill(let c), .stop(let c), .start(let c): return c
            }
        }
    }

    private var runningContainers: [ContainerDTO] {
        containers.filter { $0.status == "running" }
    }

    private var otherContainers: [ContainerDTO] {
        containers.filter { $0.status != "running" }
    }

    var body: some View {
        ZStack {
            if isLoading && containers.isEmpty {
                ProgressView()
                    .tint(.tronIndigo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                errorView(error)
            } else if containers.isEmpty {
                emptyView
            } else {
                containerList
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            onNavigationModeChange?(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image("TronLogo")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                        .foregroundStyle(.tronIndigo)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("SANDBOXES")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronIndigo)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronIndigo)
                }
            }
        }
        .sheet(item: $selectedContainer) { container in
            ContainerDetailSheet(
                container: container,
                tailscaleIp: tailscaleIp,
                onOpenURL: { url in
                    safariURL = url
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { safariURL != nil },
            set: { if !$0 { safariURL = nil } }
        )) {
            if let url = safariURL {
                SafariView(url: url)
            }
        }
        .alert("Kill Container?", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) {
                containerAction = nil
            }
            Button("Kill", role: .destructive) {
                if let action = containerAction {
                    performAction(action)
                }
            }
        } message: {
            if let action = containerAction {
                Text("This will immediately terminate all processes in \"\(action.container.name)\".")
            }
        }
        .alert("Action Failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = actionError {
                Text(error)
            }
        }
        .task {
            await loadContainers()
        }
        .refreshable {
            await loadContainers()
        }
    }

    // MARK: - Container List

    private var containerList: some View {
        List {
            if !runningContainers.isEmpty {
                Section {
                    ForEach(runningContainers) { container in
                        containerRow(container, dimmed: false)
                    }
                } header: {
                    sectionHeader("Running", color: .green)
                }
            }

            if !otherContainers.isEmpty {
                Section {
                    ForEach(otherContainers) { container in
                        containerRow(container, dimmed: true)
                    }
                } header: {
                    sectionHeader("Stopped", color: .white.opacity(0.4))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func containerRow(_ container: ContainerDTO, dimmed: Bool) -> some View {
        ContainerRow(container: container)
            .opacity(actionInProgress == container.name ? 0.5 : (dimmed ? 0.6 : 1.0))
            .overlay {
                if actionInProgress == container.name {
                    ProgressView()
                        .tint(.tronIndigo)
                }
            }
            .onTapGesture { selectedContainer = container }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButtons(for: container)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
    }

    @ViewBuilder
    private func swipeButtons(for container: ContainerDTO) -> some View {
        Button(role: .destructive) {
            containerAction = .kill(container)
            showKillConfirmation = true
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .tint(.red)

        if container.status == "running" {
            Button {
                performAction(.stop(container))
            } label: {
                Image(systemName: "stop.fill")
            }
            .tint(.orange)
        } else if container.status == "stopped" {
            Button {
                performAction(.start(container))
            } label: {
                Image(systemName: "play.fill")
            }
            .tint(.green)
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            Text(title.uppercased())
                .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(color)
                .tracking(1.5)
            Spacer()
        }
    }

    // MARK: - Actions

    private func performAction(_ action: ContainerAction) {
        let name = action.container.name
        actionInProgress = name
        containerAction = nil

        Task {
            do {
                switch action {
                case .stop(let c):
                    _ = try await rpcClient.misc.stopContainer(name: c.name)
                case .start(let c):
                    _ = try await rpcClient.misc.startContainer(name: c.name)
                case .kill(let c):
                    _ = try await rpcClient.misc.killContainer(name: c.name)
                }
                await loadContainers()
            } catch {
                actionError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    // MARK: - Empty & Error States

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(TronTypography.sans(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Containers")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Containers created by agents will appear here")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(TronTypography.sans(size: 40))
                .foregroundStyle(.red)

            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadContainers() }
            }
            .foregroundStyle(.tronIndigo)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadContainers() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await rpcClient.misc.listContainers()
            await MainActor.run {
                containers = result.containers
                tailscaleIp = result.tailscaleIp
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
