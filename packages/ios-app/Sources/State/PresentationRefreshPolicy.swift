import Foundation
import SwiftUI
import TronMobileCore

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

enum PresentationRefreshDependency: Hashable {
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

protocol PresentationReadIdentity: Equatable {
    func retainsContent(from previous: Self) -> Bool
}

extension AppModel {
    var admitsForegroundPresentationRead: Bool {
        admitsSessionPresentationOpen && !isReconcilingForeground
    }

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
