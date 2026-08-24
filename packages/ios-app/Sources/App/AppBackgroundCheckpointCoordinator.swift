import UIKit

@MainActor
struct AppBackgroundTaskAccess {
    struct Identifier: Hashable, Sendable {
        let rawValue: Int
    }

    let begin: (_ expiration: @escaping @MainActor () -> Void) -> Identifier?
    let end: (_ identifier: Identifier) -> Void

    static let live = AppBackgroundTaskAccess(
        begin: { expiration in
            let identifier = UIApplication.shared.beginBackgroundTask(
                withName: "Composer draft checkpoint",
                expirationHandler: {
                    Task { @MainActor in expiration() }
                }
            )
            guard identifier != .invalid else { return nil }
            return Identifier(rawValue: identifier.rawValue)
        },
        end: { identifier in
            UIApplication.shared.endBackgroundTask(
                UIBackgroundTaskIdentifier(rawValue: identifier.rawValue)
            )
        }
    )
}

/// Retains only the bounded composer checkpoint while iOS grants background
/// execution time. Expiration cancels both the checkpoint and its waiter before
/// releasing the UIApplication assertion.
@MainActor
final class AppBackgroundCheckpointCoordinator {
    private struct ActiveCheckpoint {
        let generation: UInt64
        let identifier: AppBackgroundTaskAccess.Identifier
        let checkpoint: Task<Void, Never>
        let waiter: Task<Void, Never>
    }

    private let access: AppBackgroundTaskAccess
    private var active: ActiveCheckpoint?
    private var generation: UInt64 = 0

    init(access: AppBackgroundTaskAccess = .live) {
        self.access = access
    }

    func retain(_ checkpoint: Task<Void, Never>) {
        cancelActiveCheckpoint()
        generation &+= 1
        let admittedGeneration = generation
        guard let identifier = access.begin({ [weak self] in
            self?.expire(generation: admittedGeneration)
        }) else {
            checkpoint.cancel()
            return
        }
        let waiter = Task { @MainActor [weak self] in
            await checkpoint.value
            guard !Task.isCancelled else { return }
            self?.complete(generation: admittedGeneration)
        }
        active = ActiveCheckpoint(
            generation: admittedGeneration,
            identifier: identifier,
            checkpoint: checkpoint,
            waiter: waiter
        )
    }

    private func complete(generation: UInt64) {
        guard let active, active.generation == generation else { return }
        self.active = nil
        access.end(active.identifier)
    }

    private func expire(generation: UInt64) {
        guard let active, active.generation == generation else { return }
        self.active = nil
        active.checkpoint.cancel()
        active.waiter.cancel()
        access.end(active.identifier)
    }

    private func cancelActiveCheckpoint() {
        guard let active else { return }
        self.active = nil
        active.checkpoint.cancel()
        active.waiter.cancel()
        access.end(active.identifier)
    }

    #if HOSTED_TEST
    var hostedHasActiveCheckpoint: Bool { active != nil }
    #endif
}
