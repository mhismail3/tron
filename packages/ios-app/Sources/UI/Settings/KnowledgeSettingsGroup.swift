import SwiftUI
import TronMobileCore

/// The Knowledge settings Connected Services opens: the interests that guide
/// source assessment and the observation coverage that needs attention.
enum KnowledgeSettingsRoute: String, Identifiable {
    case currentInterests, needsAttention
    var id: String { rawValue }
}

/// Knowledge's own settings, in Connected Services beside the services that
/// feed it. Each row opens the existing Knowledge editor; the open route
/// survives the sheet's content being rebuilt (#1073).
struct KnowledgeSettingsGroup: View {
    let accent: Color
    /// Opens a cited session from Needs attention through Settings' own route owner.
    let onOpenSession: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @PresentationState private var route: KnowledgeSettingsRoute?

    var body: some View {
        TronSettingsGroup("Knowledge", accent: accent, surfaceStyle: .glass) {
            row(.currentInterests, title: "Current interests",
                summary: "Topics that guide source assessment", icon: "text.badge.star")
            TronSettingsDivider(accent: accent)
            row(.needsAttention, title: "Needs attention",
                summary: "Observation coverage to review", icon: "exclamationmark.triangle")
        }
        .tronManagedSheet(item: $route, identity: { "integrations.knowledge.\($0.id)" }) { route in
            switch route {
            case .currentInterests:
                KnowledgeConfigurationView().environment(model)
            case .needsAttention:
                KnowledgeCoverageSheetHost(onOpenSession: openCoverageSession).environment(model)
            }
        }
        // A sheet opened for one Mac never stays up over another.
        .onChange(of: model.knowledgeDestinationIdentity) { _, _ in route = nil }
    }

    private func row(_ route: KnowledgeSettingsRoute, title: String, summary: String, icon: String) -> some View {
        Button { self.route = route } label: {
            TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("integrations.knowledge.\(route.id)")
    }

    /// A cited session opens only after its route resolves on this Gateway;
    /// Settings then retires its sheets before the chat presents.
    private func openCoverageSession(_ cut: KnowledgeObservationCoverage) {
        guard let profileID = model.knowledgePresentationIdentity.profileID else { return }
        Task { @MainActor in
            do {
                let next = try await model.navigationRoute(profileID: profileID, sessionID: cut.range.sessionId,
                                                           historyEntryID: cut.range.fromEntryId)
                guard model.ownsNavigationRoute(next) else { return }
                route = nil
                onOpenSession(next)
            } catch is CancellationError {
                return
            } catch {
                model.presentError(error)
            }
        }
    }
}
