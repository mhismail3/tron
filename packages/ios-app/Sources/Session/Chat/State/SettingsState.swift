import Foundation

/// Observable state for server-authoritative settings.
///
/// Loads values via the settings repository on first appearance and sends updates back to the server
/// when the user changes a setting. SettingsView retains this object and passes
/// `@Bindable` projections to section views.
@Observable
@MainActor
final class SettingsState {

    // MARK: - Server-Authoritative Settings

    var defaultModel: String = ""
    var quickSessionWorkspace: String = AppConstants.defaultWorkspace
    var tailscaleIp: String?
    var preserveRecentCount: Int = 5
    var triggerTokenThreshold: Double = 0.70

    // MARK: - Engine Policy

    var autonomousWorkers: Bool = false

    @ObservationIgnored
    private var lastLoadedSettings: ServerSettingsSnapshot?

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
        lastLoadedSettings = nil
        tailscaleIp = nil
    }

    func rollbackToLastLoadedSettings(message: String) {
        if let lastLoadedSettings {
            applyServerSettings(lastLoadedSettings)
            isLoaded = true
        }
        loadError = message
    }

    /// Apply a server settings snapshot to local state (shared by load and reset).
    ///
    /// Every field is overwritten from the active server's effective settings.
    /// That keeps the iOS UI honest when switching between Macs: a value that
    /// was present on server A cannot linger after server B reports its own
    /// default or a missing optional field.
    func applyServerSettings(_ settings: ServerSettingsSnapshot) {
        lastLoadedSettings = settings
        defaultModel = settings.defaultModel
        tailscaleIp = settings.tailscaleIp
        preserveRecentCount = settings.compactionPreserveRecentCount
        triggerTokenThreshold = settings.compactionTriggerTokenThreshold
        quickSessionWorkspace = settings.defaultWorkspace ?? AppConstants.defaultWorkspace
        autonomousWorkers = settings.autonomousWorkers
    }
}
