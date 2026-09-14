import Foundation
import Observation

enum InAppNoticeKey: String, Hashable, Sendable {
    case gatewayRestart
    case gatewayRecovery
    case sessionCatalogCatchUp
    case packageProgress
    case sessionCatchUp
    case sessionForked
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

/// Disposable informational feedback, not recovery authority. One FIFO head is
/// readable at a time; queued cards never cover it or consume its reading time.
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
        static let standard: Lifetime = .automatic(.seconds(4))
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

        init(id: UUID, replacement: InAppNoticeReplacement? = nil,
             scope: InAppNoticeScope = .app, role: Role = .info,
             priority: Priority = .normal, title: String, message: String? = nil,
             lifetime: Lifetime = .standard) {
            self.id = id; self.replacement = replacement; self.scope = scope
            self.role = role; self.priority = priority; self.title = title
            self.message = message; self.lifetime = lifetime
        }
    }
    static let maximumCount = 8
    static let maximumMessageBytes = 4 * 1_024
    static let maximumTotalBytes = 16 * 1_024
    static let maximumVisibleCount = 1

    private(set) var notices: [Notice] = []
    private let clock: MonotonicClock
    private var timer: Task<Void, Never>?
    private var timerToken: UUID?
    private var timedID: UUID?
    private var remaining: Duration?
    private var startedAt: ContinuousClock.Instant?
    private var backgrounded = false
    private var announcedForegroundIDs: Set<UUID> = []

    init(clock: MonotonicClock = .continuous) { self.clock = clock }

    var visibleNotices: [Notice] { Array(notices.prefix(Self.maximumVisibleCount)) }
    var foremostNoticeID: UUID? { notices.first?.id }
    var totalBytes: Int { notices.reduce(0) { $0 + $1.title.utf8.count + ($1.message?.utf8.count ?? 0) } }

    func markForegroundAnnounced(_ id: UUID) -> Bool {
        guard foremostNoticeID == id, !announcedForegroundIDs.contains(id) else { return false }
        announcedForegroundIDs.insert(id)
        return true
    }

    @discardableResult
    func post(_ notice: Notice) -> UUID {
        guard !notice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return notice.id }
        let bounded = bounded(notice)
        if let index = notices.firstIndex(where: {
            $0.id == bounded.id || (bounded.replacement != nil && $0.replacement == bounded.replacement)
        }) {
            let old = notices[index]
            notices[index] = Notice(id: old.id, replacement: bounded.replacement, scope: bounded.scope,
                                    role: bounded.role, priority: bounded.priority, title: bounded.title,
                                    message: bounded.message, lifetime: bounded.lifetime)
            // Updates retain both FIFO position and the original visible deadline.
            // Repeated progress or connection failures cannot pin the head forever.
            if old.title != bounded.title || old.message != bounded.message {
                announcedForegroundIDs.remove(old.id)
            }
            enforceBounds()
            reconcileTimer()
            return old.id
        }
        if let duplicate = notices.first(where: {
            $0.replacement == bounded.replacement && $0.scope == bounded.scope &&
            $0.role == bounded.role && $0.title == bounded.title && $0.message == bounded.message
        }) { return duplicate.id }
        notices.append(bounded)
        enforceBounds()
        reconcileTimer()
        return bounded.id
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
        announcedForegroundIDs.remove(id)
        reconcileTimer()
    }
    func dismissVisible() { if let id = foremostNoticeID { dismiss(id) } }
    func dismissAll() {
        notices.removeAll(keepingCapacity: true)
        announcedForegroundIDs.removeAll(keepingCapacity: true)
        reconcileTimer()
    }
    func retire(scope: InAppNoticeScope) {
        for id in notices.filter({ $0.scope == scope }).map(\.id) { dismiss(id) }
    }
    func setBackgrounded(_ value: Bool) {
        guard backgrounded != value else { return }
        backgrounded = value
        if value {
            if let start = startedAt, let prior = remaining {
                remaining = max(.zero, prior - (clock.now() - start))
            }
            cancelTimer()
        }
        reconcileTimer()
    }
    private func bounded(_ notice: Notice) -> Notice {
        let duration: Duration
        switch notice.lifetime {
        case .automatic(let requested): duration = min(.seconds(12), max(.seconds(2), requested))
        }
        return Notice(id: notice.id, replacement: notice.replacement, scope: notice.scope, role: notice.role,
                      priority: notice.priority, title: Self.bound(notice.title), message: notice.message.map(Self.bound),
                      lifetime: .automatic(duration))
    }
    private func enforceBounds() {
        while notices.count > Self.maximumCount || totalBytes > Self.maximumTotalBytes {
            // Never evict/preempt the card being read. Priority only decides
            // which pending feedback to shed under a burst, not display order.
            guard let victim = notices.dropFirst().min(by: { $0.priority < $1.priority }) else { break }
            notices.removeAll { $0.id == victim.id }
            announcedForegroundIDs.remove(victim.id)
        }
    }
    private func reconcileTimer() {
        if timedID != foremostNoticeID {
            cancelTimer()
            timedID = foremostNoticeID
            remaining = notices.first.map {
                switch $0.lifetime { case .automatic(let duration): duration }
            }
        }
        guard !backgrounded, timer == nil, let id = timedID, let duration = remaining else { return }
        guard duration > .zero else { dismiss(id); return }
        let token = UUID()
        timerToken = token
        startedAt = clock.now()
        let clock = clock
        timer = Task { @MainActor [weak self] in
            do { try await clock.sleep(duration) } catch { return }
            guard let self, self.timerToken == token, self.foremostNoticeID == id else { return }
            self.dismiss(id)
        }
    }
    private func cancelTimer() {
        timer?.cancel(); timer = nil; timerToken = nil; startedAt = nil
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
