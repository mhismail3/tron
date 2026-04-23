import SwiftUI

/// Privacy settings page (Phase 7).
///
/// Hosts:
/// - Telemetry opt-in toggle (default OFF, stored in
///   `@AppStorage("telemetryEnabled")` under the key shared by
///   `OnboardingState.telemetryConsentStorageKey`).
/// - Event list — rendered from `TelemetryEvent.allCasesForDocumentation`
///   so the page is always in sync with the code.
/// - "Send feedback" — opens the system mail composer with a redacted
///   log-tail attached. Falls back to a "Mail isn't configured"
///   message when `MFMailComposeViewController.canSendMail()` returns
///   false.
///
/// NB: telemetry collection is gated here AND by the enabled branch
/// inside `TelemetryClientFactory.make(enabled:)` — so flipping the
/// toggle off stops emission immediately, even for long-lived
/// instances of the client.
struct PrivacySettingsPage: View {
    @AppStorage(OnboardingState.telemetryConsentStorageKey) private var telemetryEnabled = false

    @State private var showMailComposer = false
    @State private var mailSubject = ""
    @State private var mailBody = ""
    @State private var showMailUnavailableAlert = false

    var body: some View {
        SettingsPageContainer(title: "Privacy") {
            telemetryCard
            eventListCard
            feedbackCard
        }
        .sheet(isPresented: $showMailComposer) {
            FeedbackMailView(
                subject: mailSubject,
                body: mailBody,
                recipient: FeedbackComposer.recipient,
                onDismiss: { showMailComposer = false }
            )
            .ignoresSafeArea()
        }
        .alert("Mail isn't configured", isPresented: $showMailUnavailableAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Set up a mail account in iOS Settings > Mail, then try again.")
        }
    }

    // MARK: - Telemetry

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Telemetry")

            SettingsCard {
                SettingsRow(icon: "chart.bar.xaxis", label: "Share anonymous usage data") {
                    Toggle("", isOn: $telemetryEnabled)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "Anonymous event counts help us spot crashes + rough feature usage. No chat content, no auth tokens, no user identifiers. Off by default.")
        }
    }

    // MARK: - Event list

    private var eventListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Events we collect")

            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(TelemetryEvent.allCasesForDocumentation, id: \.name) { event in
                        Text("• \(event.name)")
                            .font(TronTypography.code(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }

            SettingsCaption(text: "Source of truth: TelemetryEvent enum. If you see an event here and don't recognize it, file an issue — the list should never grow without a PR.")
        }
    }

    // MARK: - Feedback

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Feedback")

            SettingsCard(interactive: true) {
                Button {
                    presentFeedbackComposer()
                } label: {
                    SettingsRow(icon: "envelope", label: "Send feedback") {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsCaption(text: "Opens Mail with the last 200 log lines attached. Bearer tokens and file paths are redacted — review before sending.")
        }
    }

    // MARK: - Actions

    private func presentFeedbackComposer() {
        guard FeedbackMailAvailability.canSendMail() else {
            showMailUnavailableAlert = true
            return
        }
        let composer = FeedbackComposer(
            appVersion: AppConstants.appVersion,
            buildNumber: AppConstants.buildNumber
        )
        let logs = Self.recentLogs()
        mailSubject = composer.subject()
        mailBody = composer.assembleBody(userNotes: "", logs: logs)
        showMailComposer = true
    }

    /// Pulls recent logs from `TronLogger` if available. Production
    /// (non-DEBUG/BETA) builds return an empty slice; `FeedbackComposer`
    /// renders "no logs captured" in that case.
    private static func recentLogs() -> [(Date, LogCategory, LogLevel, String)] {
        #if DEBUG || BETA
        return TronLogger.shared.getRecentLogs(count: FeedbackComposer.defaultLogTailLimit)
        #else
        return []
        #endif
    }
}
