import SwiftUI

extension SettingsView {
    // MARK: - Main Sections

    var mainSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsListLayout.sectionSpacing) {
            VStack(spacing: MainSettingsListLayout.rowSpacing) {
                ForEach(MainSettingsGridDestination.order, id: \.self) { destination in
                    SettingsCard {
                        mainSettingsDestinationRow(destination)
                    }
                }
            }

            if showsServerUnavailableState {
                serverUnavailableCard
            }

            mainSettingsDivider

            VStack(alignment: .leading, spacing: MainSettingsListLayout.rowSpacing) {
                SettingsSectionHeader(title: "Danger Zone")

                VStack(spacing: MainSettingsListLayout.rowSpacing) {
                    ForEach(SettingsDangerZoneAction.order, id: \.self) { action in
                        SettingsCard(accent: dangerActionAccent(action)) {
                            dangerActionRow(action)
                        }
                    }
                }
            }
        }
    }

    func mainSettingsDestinationRow(_ destination: MainSettingsGridDestination) -> some View {
        let enabled = isMainSettingsDestinationEnabled(destination)
        return Button {
            openMainSettingsDestination(destination)
        } label: {
            SettingsRow(
                icon: destination.icon,
                label: destination.title,
                accentColor: mainSettingsDestinationAccent(destination),
                labelColor: enabled ? .tronTextPrimary : .tronTextMuted
            ) {
                Text(destination.description)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.44)
        .accessibilityHint(destination.accessibilityHint)
    }

    func dangerActionRow(_ action: SettingsDangerZoneAction) -> some View {
        let enabled = isDangerActionEnabled(action)
        return Button {
            performDangerAction(action)
        } label: {
            SettingsRow(
                icon: action.displayIcon(workersStopped: workersStopped),
                label: action.displayTitle(workersStopped: workersStopped),
                accentColor: dangerActionAccent(action),
                labelColor: dangerActionAccent(action)
            ) {
                if isDangerActionInProgress(action) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(dangerActionAccent(action))
                } else if action == .stopAllWorkers, workerDispatchError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.tronWarning)
                        .accessibilityLabel("Worker dispatch state unavailable")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    var mainSettingsDivider: some View {
        Rectangle()
            .fill(Color.tronTextMuted.opacity(MainSettingsListLayout.dividerOpacity))
            .frame(height: MainSettingsListLayout.dividerHeight)
            .padding(.horizontal, MainSettingsListLayout.dividerHorizontalPadding)
            .padding(.vertical, MainSettingsListLayout.dividerVerticalPadding)
    }

    func isMainSettingsDestinationEnabled(_ destination: MainSettingsGridDestination) -> Bool {
        switch destination {
        case .engine, .app, .logs:
            return true
        case .providers, .artifacts:
            return serverSettingsReady
        }
    }

    func mainSettingsDestinationAccent(_ destination: MainSettingsGridDestination) -> Color {
        switch destination {
        case .app:
            return MainSettingsLocalCategoryStyle.accent
        default:
            return .tronEmerald
        }
    }

    func openMainSettingsDestination(_ destination: MainSettingsGridDestination) {
        switch destination {
        case .engine:
            activePage = .engine
        case .app:
            activePage = .app
        case .providers:
            activePage = .providers
        case .artifacts:
            activePage = .artifacts
        case .logs:
            showLogViewer = true
        }
    }

    var serverUnavailableCard: some View {
        SettingsCard(accent: .tronWarning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: serverUnavailableIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverUnavailableTitle)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(serverUnavailableDescription)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isRecoveringServerConnection {
                    Label("Server content will catch up automatically", systemImage: "clock.arrow.circlepath")
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody3,
                            weight: .medium
                        ))
                        .foregroundStyle(.tronTextSecondary)
                        .padding(.leading, MainSettingsListLayout.unavailableActionLeadingPadding)
                } else {
                    HStack(spacing: 8) {
                        Button("Retry") {
                            Task {
                                await dependencies.manualRetry()
                                await loadServerSettingsIfAvailable()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.tronEmerald)

                        Button(SettingsLabels.repairActiveServerPairing) {
                            startOnboarding(prefill: dependencies.pairedServerStore.activeServer)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .padding(.leading, MainSettingsListLayout.unavailableActionLeadingPadding)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    func isDangerActionEnabled(_ action: SettingsDangerZoneAction) -> Bool {
        action.isEnabled(
            hasSessions: !eventStoreManager.sessions.isEmpty,
            workerDispatchReady: workerDispatchLoaded && dependencies.connectionRepository.connectionState.isConnected,
            serverSettingsReady: serverSettingsReady,
            serverSettingsUnavailable: showsServerUnavailableState,
            isInProgress: isDangerActionInProgress(action)
        )
    }

    func isDangerActionInProgress(_ action: SettingsDangerZoneAction) -> Bool {
        switch action {
        case .stopAllWorkers:
            return isChangingWorkerDispatch || (
                dependencies.connectionRepository.connectionState.isConnected
                    && !workerDispatchLoaded
                    && workerDispatchError == nil
            )
        case .archiveAllSessions:
            return isArchivingAll
        case .resetAllSettings:
            return false
        }
    }

    func performDangerAction(_ action: SettingsDangerZoneAction) {
        switch action {
        case .stopAllWorkers:
            showWorkerDispatchConfirmation = true
        case .archiveAllSessions:
            showArchiveAllConfirmation = true
        case .resetAllSettings:
            showingResetAlert = true
        }
    }

    func dangerActionAccent(_ action: SettingsDangerZoneAction) -> Color {
        action == .stopAllWorkers && workersStopped ? .tronEmerald : .tronError
    }

    var settingsFooterDockView: some View {
        footerView
            .padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)
            .padding(.vertical, MainSettingsFooterLayout.verticalPadding)
            .frame(maxWidth: .infinity)
            .cardEntrance(visible: cardsVisible, index: 1)
    }

    var footerView: some View {
        footerText
            .frame(maxWidth: .infinity)
    }

    var footerText: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, MainSettingsFooterLayout.taglineLeadingPadding)
            .lineLimit(1)
            .minimumScaleFactor(0.92)
    }

}
