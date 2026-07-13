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
                        SettingsCard(accent: .tronError) {
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
                icon: action.icon,
                label: action.title,
                accentColor: .tronError,
                labelColor: .tronError
            ) {
                if isDangerActionInProgress(action) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.tronError)
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
        case .engine, .app:
            return true
        case .providers:
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
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    func isDangerActionEnabled(_ action: SettingsDangerZoneAction) -> Bool {
        action.isEnabled(
            hasSessions: !eventStoreManager.sessions.isEmpty,
            serverSettingsReady: serverSettingsReady,
            serverSettingsUnavailable: showsServerUnavailableState,
            isInProgress: isDangerActionInProgress(action)
        )
    }

    func isDangerActionInProgress(_ action: SettingsDangerZoneAction) -> Bool {
        switch action {
        case .archiveAllSessions:
            return isArchivingAll
        case .resetAllSettings:
            return false
        }
    }

    func performDangerAction(_ action: SettingsDangerZoneAction) {
        switch action {
        case .archiveAllSessions:
            showArchiveAllConfirmation = true
        case .resetAllSettings:
            showingResetAlert = true
        }
    }

    var settingsFooterDockView: some View {
        ZStack(alignment: .bottom) {
            SettingsFooterBackdrop()
            footerView
                .padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)
                .padding(.top, MainSettingsFooterLayout.topPadding)
                .padding(.bottom, MainSettingsFooterLayout.bottomPadding)
        }
            .frame(maxWidth: .infinity)
            .frame(height: MainSettingsFooterLayout.dockHeight)
            .cardEntrance(visible: cardsVisible, index: 1)
    }

    var footerView: some View {
        HStack(alignment: .center, spacing: 12) {
            footerText
            Spacer(minLength: 12)
            feedbackFooterButton
        }
        .frame(maxWidth: .infinity)
    }

    var footerText: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.92)
            .padding(.leading, MainSettingsFooterLayout.textLeadingPadding)
    }

    var feedbackFooterButton: some View {
        let shape = RoundedRectangle(
            cornerRadius: MainSettingsFooterLayout.feedbackButtonCornerRadius,
            style: .continuous
        )
        return Button {
            prepareAndPresentFeedback()
        } label: {
            Text("Send Feedback")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .footerFeedbackButtonChrome()
        .disabled(isPreparingFeedback)
        .opacity(isPreparingFeedback ? 0.55 : 1)
    }


}
