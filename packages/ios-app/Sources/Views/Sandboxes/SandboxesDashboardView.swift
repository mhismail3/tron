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
        .task {
            await loadContainers()
        }
        .refreshable {
            await loadContainers()
        }
    }

    // MARK: - Container List

    private var containerList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !runningContainers.isEmpty {
                    sectionHeader("Running", color: .green)
                    ForEach(runningContainers) { container in
                        ContainerRow(container: container)
                            .onTapGesture { selectedContainer = container }
                    }
                }

                if !otherContainers.isEmpty {
                    sectionHeader("Stopped", color: .white.opacity(0.4))
                    ForEach(otherContainers) { container in
                        ContainerRow(container: container)
                            .opacity(0.6)
                            .onTapGesture { selectedContainer = container }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            Text(title.uppercased())
                .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(color)
                .tracking(1.5)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.leading, 4)
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
