import SwiftUI

@available(iOS 26.0, *)
struct AutomationsDashboardView: View {
    let rpcClient: RPCClient
    let onSettings: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?
    var notificationUnreadCount: Int = 0
    var onNotificationBell: (() -> Void)? = nil

    @State private var jobs: [CronJobDTO] = []
    @State private var runtimeStates: [String: CronRuntimeStateDTO] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedJob: CronJobDTO?
    @State private var showCreateSheet = false
    @State private var jobToDelete: CronJobDTO?
    @State private var showDeleteConfirmation = false
    @State private var actionInProgress: String?
    @State private var actionError: String?

    private var activeJobs: [CronJobDTO] {
        jobs.filter(\.enabled).sorted { $0.name < $1.name }
    }

    private var pausedJobs: [CronJobDTO] {
        jobs.filter { !$0.enabled }.sorted { $0.name < $1.name }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isLoading && jobs.isEmpty {
                ProgressView()
                    .tint(.tronCoral)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                errorView(error)
            } else if jobs.isEmpty {
                emptyView
            } else {
                jobList
            }

            // Floating create button
            Image(systemName: "plus")
                .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                .foregroundStyle(.tronCoral)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
                .glassEffect(.regular.tint(Color.tronCoral.opacity(0.25)).interactive(), in: .circle)
                .onTapGesture { showCreateSheet = true }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
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
                    Image("TronLogoVector")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                        .offset(y: 1)
                        .foregroundStyle(.tronCoral)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("Automations")
                    .font(TronTypography.mono(size: 20, weight: .bold))
                    .foregroundStyle(.tronCoral)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if notificationUnreadCount > 0 {
                        NotificationBellButton(
                            unreadCount: notificationUnreadCount,
                            accent: .tronCoral,
                            action: { onNotificationBell?() }
                        )
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronCoral)
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.3), value: notificationUnreadCount > 0)
            }
        }
        .sheet(item: $selectedJob) { job in
            AutomationDetailSheet(
                rpcClient: rpcClient,
                job: job,
                runtimeState: runtimeStates[job.id],
                onTrigger: { triggerJob(job) },
                onDelete: {
                    selectedJob = nil
                    jobToDelete = job
                    showDeleteConfirmation = true
                },
                onToggleEnabled: {
                    toggleEnabled(job)
                }
            )
        }
        .sheet(isPresented: $showCreateSheet) {
            AutomationFormSheet(
                rpcClient: rpcClient,
                onSaved: {
                    showCreateSheet = false
                    Task { await loadJobs() }
                },
                onCancel: { showCreateSheet = false }
            )
        }
        .alert("Delete Automation?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                jobToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let job = jobToDelete {
                    deleteJob(job)
                }
            }
        } message: {
            if let job = jobToDelete {
                Text("This will permanently delete \"\(job.name)\". Run history will be preserved.")
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
            await loadJobs()
        }
        .refreshable {
            await loadJobs()
        }
    }

    // MARK: - Job List

    private var jobList: some View {
        List {
            if !activeJobs.isEmpty {
                Section {
                    ForEach(activeJobs) { job in
                        jobRow(job)
                    }
                } header: {
                    sectionHeader("Active", count: activeJobs.count, color: .tronCoral)
                }
            }

            if !pausedJobs.isEmpty {
                Section {
                    ForEach(pausedJobs) { job in
                        jobRow(job)
                    }
                } header: {
                    sectionHeader("Paused", count: pausedJobs.count, color: .tronTextMuted)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func jobRow(_ job: CronJobDTO) -> some View {
        AutomationRow(job: job, runtimeState: runtimeStates[job.id])
            .opacity(actionInProgress == job.id ? 0.5 : (!job.enabled ? 0.6 : 1.0))
            .overlay {
                if actionInProgress == job.id {
                    ProgressView()
                        .tint(.tronCoral)
                }
            }
            .onTapGesture { selectedJob = job }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    jobToDelete = job
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .tint(.red)

                Button {
                    toggleEnabled(job)
                } label: {
                    Image(systemName: job.enabled ? "pause.fill" : "play.fill")
                }
                .tint(job.enabled ? .orange : .green)
            }
            .swipeActions(edge: .leading) {
                Button {
                    triggerJob(job)
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .tint(.tronCoral)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Text(title)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(color)
            Text("(\(count))")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(color.opacity(0.6))
            Spacer()
        }
    }

    // MARK: - Actions

    private func toggleEnabled(_ job: CronJobDTO) {
        actionInProgress = job.id
        Task {
            do {
                _ = try await rpcClient.cron.updateJob(jobId: job.id, enabled: !job.enabled)
                await loadJobs()
            } catch {
                actionError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    private func triggerJob(_ job: CronJobDTO) {
        actionInProgress = job.id
        Task {
            do {
                _ = try await rpcClient.cron.triggerJob(jobId: job.id)
            } catch {
                actionError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    private func deleteJob(_ job: CronJobDTO) {
        actionInProgress = job.id
        jobToDelete = nil
        Task {
            do {
                _ = try await rpcClient.cron.deleteJob(jobId: job.id)
                await loadJobs()
            } catch {
                actionError = error.localizedDescription
            }
            actionInProgress = nil
        }
    }

    // MARK: - Empty & Error States

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.badge.checkmark")
                .font(TronTypography.sans(size: 48, weight: .light))
                .foregroundStyle(.tronTextMuted)

            VStack(spacing: 6) {
                Text("No Automations")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("Scheduled jobs created by agents or from here will appear")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronTextMuted)
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
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadJobs() }
            }
            .foregroundStyle(.tronCoral)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadJobs() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await rpcClient.cron.listJobs()
            await MainActor.run {
                jobs = result.jobs
                runtimeStates = Dictionary(
                    result.runtimeState.map { ($0.jobId, $0) },
                    uniquingKeysWith: { _, last in last }
                )
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
