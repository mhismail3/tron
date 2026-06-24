import SwiftUI

extension SettingsView {
    // MARK: - Main Sections

    var mainSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsGridLayout.rowSpacing) {
            LazyVGrid(columns: mainSettingsDestinationGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(
                    MainSettingsGridDestination.visibleDestinations(
                        serverSettingsUnavailable: showsServerUnavailableState
                    ),
                    id: \.self
                ) { destination in
                    mainSettingsDestinationTile(destination)
                }
            }

            if showsServerUnavailableState {
                serverUnavailableCard
            }

            mainSettingsDivider

            LazyVGrid(columns: mainSettingsDangerGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(SettingsDangerZoneAction.order, id: \.self) { action in
                    dangerActionTile(action)
                }
            }
        }
    }

    var mainSettingsDivider: some View {
        Rectangle()
            .fill(Color.tronTextMuted.opacity(MainSettingsGridLayout.dividerOpacity))
            .frame(height: MainSettingsGridLayout.dividerHeight)
            .padding(.horizontal, MainSettingsGridLayout.dividerHorizontalPadding)
            .padding(.vertical, MainSettingsGridLayout.dividerVerticalPadding)
    }

    var mainSettingsDestinationGridColumns: [GridItem] {
        mainSettingsGridColumns(
            count: MainSettingsGridLayout.destinationColumnCount(
                serverSettingsUnavailable: showsServerUnavailableState
            )
        )
    }

    var mainSettingsDangerGridColumns: [GridItem] {
        mainSettingsGridColumns(count: MainSettingsGridLayout.columnCount)
    }

    func mainSettingsGridColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: MainSettingsGridLayout.columnSpacing),
            count: count
        )
    }

    func mainSettingsDestinationTile(_ destination: MainSettingsGridDestination) -> some View {
        let enabled = isMainSettingsDestinationEnabled(destination)
        return SettingsCard(
            accent: mainSettingsDestinationAccent(destination),
            interactive: enabled
        ) {
            Button {
                openMainSettingsDestination(destination)
            } label: {
                mainSettingsDestinationTileContent(
                    icon: destination.icon,
                    title: destination.title,
                    description: destination.description,
                    accent: mainSettingsDestinationAccent(destination),
                    minHeight: MainSettingsGridLayout.destinationTileMinHeight
                )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .accessibilityHint(destination.accessibilityHint)
        }
    }

    func isMainSettingsDestinationEnabled(_ destination: MainSettingsGridDestination) -> Bool {
        switch destination {
        case .server, .app:
            return true
        case .providers, .agent, .context:
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
        case .server:
            if hasPairedServers {
                activePage = .server
            } else {
                startOnboarding()
            }
        case .app:
            activePage = .app
        case .providers:
            activePage = .providers
        case .agent:
            activePage = .agent
        case .context:
            activePage = .context
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
                .padding(.leading, MainSettingsGridLayout.unavailableActionLeadingPadding)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    func mainSettingsDestinationTileContent(
        icon: String,
        title: String,
        description: String,
        accent: Color,
        minHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.destinationTitleSize, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, MainSettingsGridLayout.iconFrameSize + 8)

                Text(description)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.destinationDescriptionSize, weight: .medium))
                    .foregroundStyle(.tronTextMuted.opacity(MainSettingsGridLayout.destinationDescriptionOpacity))
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MainSettingsGridLayout.destinationDescriptionTopPadding)

                Spacer(minLength: 0)
            }

            VStack {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.iconSize))
                    .foregroundStyle(accent)
                    .frame(
                        width: MainSettingsGridLayout.iconFrameSize,
                        height: MainSettingsGridLayout.iconFrameSize,
                        alignment: .leading
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func dangerActionTile(_ action: SettingsDangerZoneAction) -> some View {
        let enabled = isDangerActionEnabled(action)
        return SettingsCard(accent: .tronError, interactive: enabled) {
            Button {
                performDangerAction(action)
            } label: {
                mainSettingsTileContent(
                    icon: action.icon,
                    title: action.title,
                    accent: .tronError,
                    labelColor: .tronError,
                    minHeight: MainSettingsGridLayout.dangerTileMinHeight,
                    titleSize: MainSettingsGridLayout.dangerTitleSize,
                    titleWeight: .medium,
                    showsProgress: isDangerActionInProgress(action)
                )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
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

    func mainSettingsTileContent(
        icon: String,
        title: String,
        accent: Color,
        labelColor: Color = .tronTextPrimary,
        minHeight: CGFloat,
        titleSize: CGFloat = MainSettingsGridLayout.dangerTitleSize,
        titleWeight: Font.Weight = .medium,
        showsProgress: Bool = false
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(title)
                .font(TronTypography.sans(size: titleSize, weight: titleWeight))
                .foregroundStyle(labelColor)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, MainSettingsGridLayout.iconFrameSize + 8)

            if showsProgress {
                ProgressView()
                    .tint(accent)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.iconSize))
                    .foregroundStyle(accent)
                    .frame(
                        width: MainSettingsGridLayout.iconFrameSize,
                        height: MainSettingsGridLayout.iconFrameSize,
                        alignment: .leading
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var pinnedFooterView: some View {
        footerView
            .padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)
            .padding(.top, MainSettingsFooterLayout.topPadding)
            .padding(.bottom, MainSettingsFooterLayout.bottomPadding)
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
