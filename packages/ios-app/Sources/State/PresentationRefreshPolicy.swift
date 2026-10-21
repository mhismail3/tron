import Foundation
import SwiftUI
import TronMobileCore

/// A sheet source declares a shared read that its foremost editor depends on.
/// The native surface owns admission/cancellation; the existing read owner
/// deduplicates the target and publishes one complete snapshot.
@MainActor
struct PresentationDependencyRead {
    struct ID: Hashable { let target: JSONValue; let freshness: SettingsFreshness }
    let id: ID
    let perform: @MainActor () async -> Void
}

private struct PresentationDependencyReadKey: EnvironmentKey {
    static var defaultValue: PresentationDependencyRead? { nil }
}

extension EnvironmentValues {
    var tronPresentationDependencyRead: PresentationDependencyRead? {
        get { self[PresentationDependencyReadKey.self] }
        set { self[PresentationDependencyReadKey.self] = newValue }
    }
}

/// A foremost presentation can require underlying session authority without
/// asking covered views to refresh their own presentation work.
enum PresentationRefreshDependency: Hashable {
    /// The catalog is consumed by its declared surface, not inherited by editors.
    case sessionCatalog
    case session(String)
    case queuedMessage(sessionID: String, messageID: String)

    func requiresSession(_ id: String) -> Bool {
        switch self {
        case .sessionCatalog: false
        case .session(let sessionID), .queuedMessage(let sessionID, _): sessionID == id
        }
    }
}

/// Read admission can change without replacing what a presentation is showing.
/// Retained content is display-only; each read and mutation still requires current admission.
protocol PresentationReadIdentity: Equatable {
    func retainsContent(from previous: Self) -> Bool
}

extension AppModel {
    func restoreForemostPresentationAfterReconnect() async -> Bool {
        if let target = mountedPresentationTarget,
           foregroundPresentationActivity?.requiresSessionRefresh(target.sessionID) == false { return true }
        return await restoreMountedPresentationAfterReconnect()
    }
}

extension HomeSheetReadIdentity: PresentationReadIdentity {
    func retainsContent(from previous: Self) -> Bool {
        profileID == previous.profileID && surfaceToken == previous.surfaceToken
    }
}

extension SessionHistoryReadIdentity: PresentationReadIdentity {
    func retainsContent(from previous: Self) -> Bool {
        profileID == previous.profileID && target == previous.target
            && runtimeGeneration == previous.runtimeGeneration
    }
}
