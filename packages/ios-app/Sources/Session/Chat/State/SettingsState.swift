import Foundation

/// The only settings projection retained outside native UI. Onboarding and
/// new-session flows need these defaults even when no native UI surface is open.
struct SessionDefaultsSnapshot: Equatable, Sendable {
    var defaultWorkspace: String
    var defaultModel: String

    static let empty = SessionDefaultsSnapshot(
        defaultWorkspace: AppConstants.defaultWorkspace,
        defaultModel: ""
    )
}

/// Observable loading state for the minimal external session-defaults projection.
///
/// Loads values via the settings repository on first appearance and sends updates back to the server
/// when the user changes a setting. SettingsView retains this object and passes
/// `@Bindable` projections to section views.
@Observable
@MainActor
final class SettingsState {

    var sessionDefaults: SessionDefaultsSnapshot = .empty

    var defaultModel: String {
        get { sessionDefaults.defaultModel }
        set { sessionDefaults.defaultModel = newValue }
    }

    var quickSessionWorkspace: String {
        get { sessionDefaults.defaultWorkspace }
        set { sessionDefaults.defaultWorkspace = newValue }
    }

    // MARK: - Load State

    var isLoaded = false
    var loadError: String?

    // MARK: - Init

    init() {}

    // MARK: - Display Helpers

    var displayQuickSessionWorkspace: String {
        quickSessionWorkspace.abbreviatingHomeDirectory
    }

    // MARK: - Load from Server

    func load(
        using settingsRepository: any SettingsRepository,
        acceptResult: @escaping @MainActor () -> Bool = { true }
    ) async {
        guard !isLoaded else { return }
        do {
            let settings = try await settingsRepository.get()
            guard acceptResult() else { return }
            applyServerSettings(settings)
            isLoaded = true
        } catch {
            guard acceptResult() else { return }
            loadError = error.localizedDescription
        }
    }

    // MARK: - Reset

    /// Reset settings to server defaults through the engine. The server applies its own defaults
    /// and returns the new values — no hardcoded defaults on the client.
    @discardableResult
    func resetToDefaults(
        using settingsRepository: any SettingsRepository,
        acceptResult: @escaping @MainActor () -> Bool = { true }
    ) async throws -> ServerSettingsSnapshot {
        let settings = try await settingsRepository.resetToDefaults(
            idempotencyKey: .userAction("settings.resetToDefaults")
        )
        guard acceptResult() else { return settings }
        applyServerSettings(settings)
        return settings
    }

    func clearServerSnapshot() {
        isLoaded = false
        loadError = nil
        sessionDefaults = .empty
    }

    /// Apply a server settings snapshot to local state (shared by load and reset).
    ///
    /// Only external defaults are copied. Every other server-owned setting is
    /// bound directly into the native UI settings surface and has no duplicate
    /// observable ownership in iOS.
    func applyServerSettings(_ settings: ServerSettingsSnapshot) {
        sessionDefaults = SessionDefaultsSnapshot(
            defaultWorkspace: settings.defaultWorkspace ?? AppConstants.defaultWorkspace,
            defaultModel: settings.defaultModel
        )
    }
}
