import Foundation
import Observation

enum InAppNoticeKey: String, Hashable, Sendable {
    case gatewayRestart
    case packageProgress
    case sessionCatchUp
    case onboardingError
}

enum InAppNoticeScope: Hashable, Sendable {
    case app
    case presentation(UUID)
    case session(id: String, generation: Int)
}

struct InAppNoticeReplacement: Hashable, Sendable {
    let key: InAppNoticeKey
    let scope: InAppNoticeScope
}

/// Presentation-only state for short-lived application feedback. The Gateway
/// remains authoritative; this center never persists or replays notices.
@MainActor
@Observable
final class InAppNoticeCenter {
    enum Role: String, Equatable, Sendable { case info, success, warning, error, progress }
    enum Priority: Int, Comparable, Sendable {
        case low = 0, normal = 1, high = 2
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    enum Lifetime: Equatable, Sendable {
        case automatic(Duration)
        case persistent
        static let standard: Lifetime = .automatic(.seconds(4))
    }
    struct Action: Equatable, Sendable, Identifiable {
        let id: String; let title: String; let role: ButtonRole
        enum ButtonRole: String, Equatable, Sendable { case normal, cancel, destructive }
    }
    struct Notice: Identifiable, Equatable, Sendable {
        let id: UUID
        let replacement: InAppNoticeReplacement?
        let scope: InAppNoticeScope
        let role: Role
        let priority: Priority
        let title: String
        let message: String?
        let lifetime: Lifetime
        let actions: [Action]

        init(id: UUID, replacement: InAppNoticeReplacement? = nil,
             scope: InAppNoticeScope = .app, role: Role = .info,
             priority: Priority = .normal, title: String, message: String? = nil,
             lifetime: Lifetime = .standard, actions: [Action] = []) {
            self.id = id; self.replacement = replacement; self.scope = scope
            self.role = role; self.priority = priority; self.title = title
            self.message = message; self.lifetime = lifetime; self.actions = Array(actions.prefix(2))
        }
    }
    static let maximumCount = 8
    static let maximumMessageBytes = 4 * 1_024
    static let maximumTotalBytes = 16 * 1_024
    static let maximumVisibleCount = 3

    private(set) var notices: [Notice] = []
    private let clock: MonotonicClock
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var timerTokens: [UUID: UUID] = [:]
    private var remaining: [UUID: Duration] = [:]
    private var startedAt: [UUID: ContinuousClock.Instant] = [:]
    private var interactionHolds: Set<UUID> = []
    private var backgrounded = false
    private var handlers: [UUID: [String: @MainActor () -> Void]] = [:]
    private var announcedForegroundIDs: Set<UUID> = []

    init(clock: MonotonicClock = .continuous) { self.clock = clock }

    /// Foreground order is priority-first and FIFO within a priority.
    var visibleNotices: [Notice] {
        Array(notices.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            guard let li = notices.firstIndex(where: { $0.id == lhs.id }),
                  let ri = notices.firstIndex(where: { $0.id == rhs.id }) else { return false }
            return li < ri
        }.prefix(Self.maximumVisibleCount))
    }
    var foremostNoticeID: UUID? { visibleNotices.first?.id }
    var totalBytes: Int { notices.reduce(0) { $0 + $1.title.utf8.count + ($1.message?.utf8.count ?? 0) } }

    /// Returns true only once for a notice while it remains in the center.
    func markForegroundAnnounced(_ id: UUID) -> Bool {
        guard foremostNoticeID == id, !announcedForegroundIDs.contains(id) else { return false }
        announcedForegroundIDs.insert(id); return true
    }

    @discardableResult
    func post(_ notice: Notice, handlers: [String: @MainActor () -> Void] = [:]) -> UUID {
        guard !notice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return notice.id }
        let bounded = bounded(notice)
        if let replacement = bounded.replacement,
           let index = notices.firstIndex(where: { $0.replacement == replacement }) {
            let old = notices[index]
            cancelTimer(for: old.id)
            remaining[old.id] = nil
            interactionHolds.remove(old.id)
            let replacement = Notice(id: old.id, replacement: bounded.replacement, scope: bounded.scope,
                                     role: bounded.role, priority: bounded.priority, title: bounded.title,
                                     message: bounded.message, lifetime: bounded.lifetime, actions: bounded.actions)
            notices[index] = replacement
            self.handlers[old.id] = handlers
            // Replacing a keyed notice is a fresh user-visible event even when
            // the center preserves its stable identity for SwiftUI animation.
            announcedForegroundIDs.remove(old.id)
            reconcileTimers()
            return old.id
        }
        if bounded.replacement == nil,
           let duplicate = notices.last(where: {
               $0.replacement == nil && $0.scope == bounded.scope && $0.role == bounded.role &&
               $0.priority == bounded.priority && $0.lifetime == bounded.lifetime &&
               $0.title == bounded.title && $0.message == bounded.message && $0.actions == bounded.actions
           }) {
            // A duplicate with a new handler is still a duplicate only when its
            // action shape is identical; replace the closure map rather than lose it.
            if !handlers.isEmpty { self.handlers[duplicate.id] = handlers }
            if case .automatic(let duration) = bounded.lifetime, duration > .zero {
                // Coalescing keeps one card but gives a current automatic
                // status notice a fresh lifetime.
                cancelTimer(for: duplicate.id)
                remaining[duplicate.id] = duration
                reconcileTimers()
            }
            return duplicate.id
        }
        notices.append(bounded)
        self.handlers[bounded.id] = handlers
        enforceBounds()
        reconcileTimers()
        return bounded.id
    }

    func dismiss(_ id: UUID) { if notices.contains(where: { $0.id == id }) { remove(id) } }
    func dismissVisible() { if let id = foremostNoticeID { dismiss(id) } }
    func dismissAll() {
        for id in notices.map(\.id) { cancelTimer(for: id) }
        notices.removeAll(keepingCapacity: true); handlers.removeAll(keepingCapacity: true)
        remaining.removeAll(keepingCapacity: true); startedAt.removeAll(keepingCapacity: true)
        interactionHolds.removeAll(keepingCapacity: true); announcedForegroundIDs.removeAll(keepingCapacity: true)
        timerTokens.removeAll(keepingCapacity: true)
    }
    func retire(scope: InAppNoticeScope) { for id in notices.filter({ $0.scope == scope }).map(\.id) { remove(id) } }
    func setBackgrounded(_ value: Bool) {
        guard backgrounded != value else { return }
        if value { for notice in notices { pauseTimer(for: notice.id) } }
        backgrounded = value
        reconcileTimers()
    }
    func setInteraction(_ id: UUID, active: Bool) {
        if active { interactionHolds.insert(id); pauseTimer(for: id) }
        else { interactionHolds.remove(id); reconcileTimers() }
    }
    func performAction(_ action: Action, for id: UUID) {
        guard let notice = notices.first(where: { $0.id == id }),
              notice.actions.contains(action), let handler = handlers[id]?[action.id] else { return }
        remove(id); handler()
    }
    private func bounded(_ notice: Notice) -> Notice {
        Notice(id: notice.id, replacement: notice.replacement, scope: notice.scope, role: notice.role,
               priority: notice.priority, title: Self.bound(notice.title), message: notice.message.map(Self.bound),
               lifetime: notice.lifetime, actions: notice.actions)
    }
    private func enforceBounds() {
        while notices.count > Self.maximumCount || totalBytes > Self.maximumTotalBytes {
            guard let index = notices.firstIndex(where: { $0.priority == .low && $0.actions.isEmpty })
                ?? notices.firstIndex(where: { $0.actions.isEmpty }) else { remove(notices[0].id); continue }
            remove(notices[index].id)
        }
    }
    private func reconcileTimers() {
        let foreground = foremostNoticeID
        for notice in notices {
            guard case .automatic(let duration) = notice.lifetime, duration > .zero else {
                cancelTimer(for: notice.id); continue
            }
            if notice.id == foreground && !backgrounded && !interactionHolds.contains(notice.id) {
                scheduleIfNeeded(notice, defaultDuration: duration)
            } else {
                pauseTimer(for: notice.id)
            }
        }
    }
    private func scheduleIfNeeded(_ notice: Notice, defaultDuration: Duration) {
        guard timers[notice.id] == nil else { return }
        let value = remaining[notice.id] ?? defaultDuration
        guard value > .zero else { remove(notice.id); return }
        let token = UUID(); timerTokens[notice.id] = token
        remaining[notice.id] = value; startedAt[notice.id] = clock.now()
        timers[notice.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(value) } catch { return }
            guard self.timerTokens[notice.id] == token,
                  self.notices.contains(where: { $0.id == notice.id }) else { return }
            self.remove(notice.id)
        }
    }
    private func pauseTimer(for id: UUID) {
        guard let started = startedAt[id], let prior = remaining[id] else { return }
        let elapsed = clock.now() - started; remaining[id] = elapsed >= prior ? .zero : prior - elapsed
        cancelTimer(for: id)
    }
    private func cancelTimer(for id: UUID) {
        timers[id]?.cancel(); timers[id] = nil; timerTokens[id] = nil; startedAt[id] = nil
    }
    private func remove(_ id: UUID) {
        cancelTimer(for: id); notices.removeAll { $0.id == id }; handlers[id] = nil
        remaining[id] = nil; interactionHolds.remove(id); announcedForegroundIDs.remove(id)
        reconcileTimers()
    }
    private static func bound(_ value: String) -> String {
        guard value.utf8.count > maximumMessageBytes else { return value }
        let suffix = "…"; let budget = maximumMessageBytes - suffix.utf8.count
        var result = ""; var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= budget else { break }
            result.append(character); bytes += count
        }
        return result + suffix
    }
}
