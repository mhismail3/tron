import Foundation
import Observation

struct ConfigurationEditValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Configuration edits are commands, not presentation tasks. One profile-owned
/// queue survives sheet dismissal; only its waiting debounce is cancellable.
@MainActor @Observable
final class ConfigurationAutosaveCoordinator {
    enum Key: Hashable {
        case settings(SettingsTarget, sessionID: String?)
        case customModels(CustomModelTarget)
    }

    private struct Batch {
        let key: Key
        var patch: JSONValue?
        var write: (JSONValue?) async throws -> Void
        var completed: () -> Void
    }

    private var pending: [Batch] = []
    private var failed: [Key: Batch] = [:]
    private var messages: [Key: String] = [:]
    private var requiresExplicitRetry: Set<Key> = []
    var didFail: ((Error) -> Void)?
    private var timer: Task<Void, Never>?
    private var writing: UUID?
    private var generation = 0
    private(set) var activeKey: Key?
    private(set) var capacityError: String?

    // Retirement is synchronous; facade profile notifications can follow an
    // async connection transition. Old input must already be revoked then.
    var inputGeneration: Int { generation }

    func error(for key: Key) -> String? { messages[key] ?? capacityError }
    func canRetry(_ key: Key) -> Bool { failed[key] != nil }
    func hasPending(_ key: Key) -> Bool { activeKey == key || pending.contains { $0.key == key } }

    /// Patches contain only this user event's changed fields. Merge consecutive
    /// edits, including reversions, without manufacturing writes from a reload.
    /// A nil patch denotes a full-document operation whose latest closure wins.
    @discardableResult
    func submit(
        key: Key, patch: JSONValue? = nil,
        write: @escaping (JSONValue?) async throws -> Void,
        completed: @escaping () -> Void = {}
    ) -> Bool {
        if let patch, patch.objectValue?.isEmpty == true { return true }
        var next = Batch(key: key, patch: patch, write: write, completed: completed)
        if let previous = failed.removeValue(forKey: key) { next = merging(previous, next) }
        if requiresExplicitRetry.contains(key) {
            failed[key] = next
            return true
        }
        messages[key] = nil
        if let last = pending.last, last.key == key {
            pending[pending.count - 1] = merging(last, next)
        } else {
            // User-driven settings routes are few; never accumulate an
            // unbounded queue while a disconnected request is settling.
            guard pending.count + failed.count + (writing == nil ? 0 : 1) < 64 else {
                capacityError = "Too many pending configuration changes. Wait for the current request before editing again."
                return false
            }
            pending.append(next)
        }
        capacityError = nil
        schedule()
        return true
    }

    func retry(_ key: Key) {
        guard let batch = failed.removeValue(forKey: key) else { return }
        requiresExplicitRetry.remove(key)
        messages[key] = nil
        pending.append(batch)
        flush()
    }

    /// Leaving an editor or submitting a field need not wait out its debounce.
    func flush() {
        timer?.cancel()
        timer = nil
        startNext()
    }

    func clearProfile() {
        generation &+= 1
        timer?.cancel()
        timer = nil
        pending.removeAll()
        failed.removeAll()
        messages.removeAll()
        requiresExplicitRetry.removeAll()
        capacityError = nil
        activeKey = nil
        writing = nil
        // The accepted write remains with its mutation/receipt owner. Its old
        // generation cannot publish or dispatch another edit into this profile.
    }

    private func schedule() {
        guard writing == nil else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.startNext()
        }
    }

    private func startNext() {
        guard writing == nil, !pending.isEmpty else { return }
        let batch = pending.removeFirst()
        let token = UUID()
        let admittedGeneration = generation
        writing = token
        activeKey = batch.key
        Task {
            guard generation == admittedGeneration, writing == token else { return }
            do {
                try await batch.write(batch.patch)
                guard generation == admittedGeneration, writing == token else { return }
                messages[batch.key] = nil
                batch.completed()
            } catch {
                guard generation == admittedGeneration, writing == token else { return }
                var retained = batch
                for queued in pending where queued.key == batch.key { retained = merging(retained, queued) }
                pending.removeAll { $0.key == batch.key }
                failed[batch.key] = retained
                messages[batch.key] = error.localizedDescription
                if (error as? GatewayFailure)?.code == "outcome_unknown" {
                    requiresExplicitRetry.insert(batch.key)
                }
                // No automatic retry loop. A correction or explicit Retry may
                // resubmit a rejected edit; uncertain receipts require Retry.
                if !(error is ConfigurationEditValidationError) { didFail?(error) }
            }
            guard generation == admittedGeneration, writing == token else { return }
            writing = nil
            activeKey = nil
            if pending.count + failed.count < 64 { capacityError = nil }
            if !pending.isEmpty { schedule() }
        }
    }

    private func merging(_ older: Batch, _ newer: Batch) -> Batch {
        var result = newer
        if let old = older.patch, let new = newer.patch { result.patch = Self.merge(old, new) }
        // Earlier presentation observers are disposable; the merged command
        // retains their fields, not entire dismissed sheet hierarchies.
        return result
    }

    static func merge(_ older: JSONValue, _ newer: JSONValue) -> JSONValue {
        guard var result = older.objectValue, let additions = newer.objectValue else { return newer }
        for (key, value) in additions {
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return .object(result)
    }
}
