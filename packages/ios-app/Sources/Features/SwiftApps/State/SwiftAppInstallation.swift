import Foundation
import Observation

/// A single accepted installation, held by the Apps owner through dismissal,
/// disconnect and receipt reconciliation. A failed command is never replaced
/// or replayed by presenting the review again.
@MainActor @Observable
final class SwiftAppInstallation {
    let review: SwiftAppInstallReview
    private(set) var isInstalling = false
    private(set) var installed: InstalledSwiftAppManifest?
    private(set) var failure: String?
    private(set) var command: SwiftAppInstallCommand?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let install: @MainActor (SwiftAppInstallCommand) async throws -> SwiftAppInstallResult
    @ObservationIgnored private let didInstall: @MainActor (InstalledSwiftAppManifest) -> Void

    init(review: SwiftAppInstallReview,
         install: @escaping @MainActor (SwiftAppInstallCommand) async throws -> SwiftAppInstallResult,
         didInstall: @escaping @MainActor (InstalledSwiftAppManifest) -> Void) {
        self.review = review
        self.install = install
        self.didInstall = didInstall
    }

    func start(upgradeToV2: Bool) {
        guard command == nil else { return }
        let accepted = SwiftAppInstallCommand(commandId: UUID().uuidString.lowercased(), review: review, upgradeToV2: upgradeToV2)
        command = accepted
        isInstalling = true
        task = Task { [self] in
            defer { isInstalling = false; task = nil }
            do {
                let result = try await install(accepted)
                let app = result.app
                guard app.version == 2, app.id == review.offer.appId, app.revision == (review.installed?.revision ?? 0) + 1,
                      app.sourceSha256 == review.offer.sourceSha256, app.sourceBytes == review.offer.sourceBytes,
                      app.name == review.offer.name, app.icon == review.offer.icon, app.feeds == review.offer.feeds,
                      let instance = app.instanceId, UUID(uuidString: instance) != nil,
                      review.installed?.instanceId == nil || review.installed?.instanceId == instance else {
                    throw InstalledSwiftAppFailure("The installation result could not be verified. Check Apps before submitting another change.")
                }
                installed = app
                didInstall(app)
            } catch {
                failure = "Installation was not confirmed. \(error.localizedDescription) Check Apps before submitting another change."
            }
        }
    }
}
