import Foundation
import Observation
import TronMobileCore

extension HomeStatusTaskRecovery {
    var refusalReason: String? {
        guard case .availableFalse(let reason) = self else { return nil }
        return reason
    }
}

extension HomeStatus {
    var admitsTaskReads: Bool { available && taskRecovery == .availableTrue }

    static func validated(_ value: JSONValue) throws -> HomeStatus {
        let status = try value.decodeWire(HomeStatus.decode)
        let activationCounts: [Int?]
        let activationTexts: [String?]
        let activationStart: String?
        switch status.activation {
        case .availableFalse:
            (activationCounts, activationTexts, activationStart) = ([], [], nil)
        case .availableTrue(let start, _, let viewLines, let viewBytes, let effectiveTokens, let contextWindow, _, let refusalReason, let refusalDetail):
            (activationCounts, activationTexts, activationStart) = ([viewLines, viewBytes, effectiveTokens, contextWindow], [refusalReason, refusalDetail], start.value)
        }
        guard HomeContextProjection.statesOpen(value.objectValue?["activation"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Available activation must state whether it is open"))
        }
        let taskRecoveryValid = switch status.taskRecovery {
        case .availableTrue: true
        case .availableFalse(let reason): !reason.isEmpty && reason.utf8.count <= 1024
        }
        guard taskRecoveryValid,
              status.routeGeneration.map({ $0 > 0 }) ?? true,
              status.workers.running >= 0,
              status.readiness.gaps.count <= 128,
              status.readiness.gaps.allSatisfy({ $0.utf8.count <= 256 }),
              status.generation.map({ $0 >= 0 }) ?? true,
              status.memory.spentTokens.map({ $0 >= 0 }) ?? true,
              status.memory.episodic.map({ $0.messages >= 0 && $0.view.built >= 0 && $0.view.unbuilt >= 0
                  && $0.view.built <= $0.messages && $0.view.unbuilt <= $0.messages - $0.view.built }) ?? true,
              (status.memory.models ?? []).count <= 8 && (status.memory.models ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 421 }),
              status.chapter.map({ $0.count > 0 && ($0.currentBytes ?? 0) >= 0 && ($0.currentEntries ?? 0) >= 0 }) ?? true,
              ([status.reason, status.recovery.reason, status.memory.blocked, status.memory.reason] + activationTexts)
                .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 1_024 }),
              [status.homeId, status.sessionId, status.openSessionId, activationStart]
                .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              activationCounts.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Home status exceeds protocol bounds"))
        }
        return status
    }
}

enum HomeChatRouteKey: Equatable, Sendable {
    case home
    case ordinary(sessionID: String)

    static func forChat(sessionID: String, isHome: Bool) -> HomeChatRouteKey {
        isHome ? .home : .ordinary(sessionID: sessionID)
    }

    func matches(_ status: HomeStatus) -> Bool {
        switch self {
        case .home: true
        case .ordinary(let sessionID): status.sessionId == sessionID
        }
    }
}

enum HomeStatusLinePresentation {
    static func workers(_ status: HomeStatus) -> String {
        let count = status.workers.running
        return "\(count.formatted()) \(count == 1 ? "worker" : "workers") running"
    }

    static func host(_ status: HomeStatus) -> String {
        "Host \(status.hostPressure.level.rawValue) · \(workers(status))"
    }

    static func state(_ status: HomeStatus) -> String {
        switch status.phase {
        case .ready: "Ready"
        case .active: "Working"
        case .paused: "Paused"
        case .blocked: status.memory.configured ? "Memory blocked" : "Memory setup needed"
        case .rolloverPending, .missingSession, .unavailable: "Recovery needed"
        case .disabled: "Disabled"
        case .undesignated: "Not set up"
        }
    }

    static func memory(_ status: HomeStatus, unresolvedCommand: Bool) -> String {
        if unresolvedCommand { return "Home change unresolved" }
        if status.memory.paused == true { return "Paused" }
        if let blocked = status.memory.blocked { return "Blocked · \(blocked)" }
        if !status.memory.configured { return "Choose background models" }
        guard status.memory.open else { return "Configured" }
        guard let memory = status.memory.episodic else { return "Available" }
        let lines = memory.view.built + memory.view.unbuilt
        return "\(memory.messages.formatted()) \(memory.messages == 1 ? "message" : "messages") · \(lines.formatted()) \(lines == 1 ? "line" : "lines") in view"
    }
}

enum HomeManageRowPresentation {
    static func profile(_ list: HomeProfileList?) -> String {
        guard let list else { return "Unavailable" }
        let active = list.active
        guard !active.isEmpty else { return "Nothing learned yet" }
        let confirmed = active.filter(\.confirmed).count
        let count = active.count == 1 ? "1 item" : "\(active.count.formatted()) items"
        return "\(count) · \(confirmed.formatted()) confirmed · \((active.count - confirmed).formatted()) inferred"
    }

    static func chapters(_ list: HomeChapterList?, fallback: HomeStatusChapter?) -> String? {
        guard let list else { return fallback.map(HomeChapterPresentation.manageSubtitle) }
        let count = list.chapters.count == 1 ? "1 chapter" : "\(list.chapters.count.formatted()) chapters"
        guard let active = list.chapters.last(where: { $0.state == .active }),
              let percent = HomeChapterPresentation.softPercent(active, limits: list.limits) else { return count }
        return "\(count) · Active chapter \(percent)% of soft limit"
    }

    static func tasks(_ page: HomeTaskPage?, admitted: Bool) -> String {
        guard admitted, let page else { return "Unavailable while task recovery is closed" }
        if page.items.isEmpty { return "No tasks yet" }
        let active = page.items.filter { $0.lifecycle != .terminal }.count
        let finished = page.items.count - active
        return "\(active) active · \(finished)\(page.nextCursor == nil ? "" : "+") finished"
    }

    static func permissions(_ permissions: HomeTaskPermissionsDTO?) -> String {
        guard let permissions else { return "Unavailable while task recovery is closed" }
        return permissions.scopes.contains(where: \.active) ? "All trusted projects" : "No standing scopes"
    }
}

enum HomePinnedRowAction: Equatable {
    case checkReceipt
    case designate
    case open(sessionID: String)
    case unavailable
}

enum HomePinnedRowPolicy {
    static func action(
        for status: HomeStatus?,
        hasUnresolvedCommand: Bool = false
    ) -> HomePinnedRowAction {
        if hasUnresolvedCommand { return .checkReceipt }
        guard let status else { return .unavailable }
        switch status.phase {
        case .undesignated, .disabled, .missingSession:
            return .designate
        case .unavailable:
            return .unavailable
        case .ready, .active, .blocked, .paused, .rolloverPending:
            guard status.enabled, let sessionID = status.openSessionId, !sessionID.isEmpty else { return .unavailable }
            return .open(sessionID: sessionID)
        }
    }
}

struct HomeStatusReadFence: Equatable, Sendable {
    let profileID: String
    let connectionID: String
    let surfaceToken: PresentationSurfaceToken
    fileprivate let readGeneration: UInt64
    fileprivate let surfaceGeneration: UInt64
}

@MainActor
@Observable
final class HomeStatusPresentationOwner {
    static let fallbackInterval: Duration = .seconds(5)

    private(set) var status: HomeStatus?
    private(set) var isStatusUnavailable = false
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private var surfaceGeneration: UInt64 = 0
    @ObservationIgnored private var latestFence: HomeStatusReadFence?
    @ObservationIgnored private(set) var surfaceToken: PresentationSurfaceToken?
    @ObservationIgnored private weak var activityCoordinator: PresentationActivityCoordinator?
    @ObservationIgnored private var profileID: String?
    @ObservationIgnored private var connectionID: String?
    private(set) var capabilityEnabled = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var fetch: (@MainActor (HomeStatusReadFence) async throws -> HomeStatus)?
    @ObservationIgnored private var activeReadTask: Task<Void, Never>?
    @ObservationIgnored private var mountedTask: Task<Void, Never>?

    enum Cadence: Equatable, Sendable {
        case mounted
        case connectionOnly(HomeChatRouteKey)
        case released
    }
    @ObservationIgnored private var cadence = Cadence.mounted
    @ObservationIgnored private var claimCoverRetryUsed = false

    func mountSurface(
        token: PresentationSurfaceToken,
        coordinator: PresentationActivityCoordinator,
        cadence: Cadence = .mounted,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatus
    ) {
        guard token != surfaceToken || activityCoordinator !== coordinator else { return }
        stopWork(clearStatus: false)
        surfaceGeneration &+= 1
        surfaceToken = token
        activityCoordinator = coordinator
        self.fetch = fetch
        self.cadence = cadence
        claimCoverRetryUsed = false
        suspended = false
    }

    func configure(profileID: String, connectionID: String?, capabilityEnabled: Bool) {
        let identityChanged = self.profileID != profileID || self.connectionID != connectionID
        if identityChanged { stopWork(clearStatus: true) }
        self.profileID = profileID
        self.connectionID = connectionID
        self.capabilityEnabled = capabilityEnabled
        suspended = false
        guard capabilityEnabled else {
            stopWork(clearStatus: true)
            return
        }
        startWorkIfActive()
    }

    func connectionRetired() {
        connectionID = nil
        stopWork(clearStatus: true)
    }

    func profileRetired() {
        profileID = nil
        connectionID = nil
        capabilityEnabled = false
        stopWork(clearStatus: true)
    }

    func presentationActivityChanged(for token: PresentationSurfaceToken) {
        guard token == surfaceToken else { return }
        guard surfaceIsActive(token) else {
            stopWork(clearStatus: false)
            return
        }
        switch cadence {
        case .mounted:
            startWorkIfActive()
        case .connectionOnly:
            guard !claimCoverRetryUsed, latestFence == nil else { return }
            claimCoverRetryUsed = true
            startWorkIfActive()
        case .released:
            return
        }
    }

    func invalidateMounted(sessionID: String? = nil) async {
        guard sessionID == nil || status?.sessionId == sessionID || status?.openSessionId == sessionID else { return }
        await refreshMounted()
    }

    func refreshMounted() async {
        guard cadence == .mounted else { return }
        await startRead()?.value
    }

    func beginRead(
        profileID: String,
        connectionID: String,
        capabilityEnabled: Bool,
        token: PresentationSurfaceToken,
        coordinator: PresentationActivityCoordinator
    ) -> HomeStatusReadFence? {
        guard capabilityEnabled,
              !suspended,
              token == surfaceToken,
              coordinator === activityCoordinator,
              surfaceIsActive(token) else {
            invalidateRead(clearStatus: !capabilityEnabled)
            return nil
        }
        if self.profileID != profileID || self.connectionID != connectionID {
            status = nil
            isStatusUnavailable = false
        }
        self.profileID = profileID
        self.connectionID = connectionID
        self.capabilityEnabled = true
        readGeneration &+= 1
        let fence = HomeStatusReadFence(
            profileID: profileID,
            connectionID: connectionID,
            surfaceToken: token,
            readGeneration: readGeneration,
            surfaceGeneration: surfaceGeneration
        )
        latestFence = fence
        return fence
    }

    @discardableResult
    func publish(_ value: HomeStatus, for fence: HomeStatusReadFence) -> Bool {
        guard fence.profileID == profileID,
              fence.connectionID == connectionID,
              fence.surfaceToken == surfaceToken,
              fence.surfaceGeneration == surfaceGeneration,
              fence == latestFence,
              let coordinator = activityCoordinator,
              PresentationPublicationPolicy.allows(
                ambient: .covered,
                coordinator: coordinator,
                token: fence.surfaceToken
              ),
              !suspended else { return false }
        status = value
        isStatusUnavailable = false
        resolveClaim(with: value)
        return true
    }

    func retireSurface(_ token: PresentationSurfaceToken) {
        guard token == surfaceToken else { return }
        stopWork(clearStatus: false)
        surfaceGeneration &+= 1
        surfaceToken = nil
        activityCoordinator = nil
        fetch = nil
        suspended = false
    }

    func suspendForBackground() {
        suspended = true
        stopWork(clearStatus: true)
    }

    private func resolveClaim(with value: HomeStatus) {
        guard case .connectionOnly(let claim) = cadence else { return }
        if claim.matches(value) {
            cadence = .mounted
            startFallbackLoop()
        } else {
            cadence = .released
            stopWork(clearStatus: false)
        }
    }

    @discardableResult
    private func startRead() -> Task<Void, Never>? {
        guard !suspended, capabilityEnabled,
              let profileID, let connectionID,
              let token = surfaceToken,
              let coordinator = activityCoordinator,
              let fetch,
              surfaceIsActive(token),
              let fence = beginRead(
                profileID: profileID,
                connectionID: connectionID,
                capabilityEnabled: capabilityEnabled,
                token: token,
                coordinator: coordinator
              ) else { return nil }
        activeReadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await fetch(fence)
                if !Task.isCancelled { _ = self.publish(value, for: fence) }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, fence == self.latestFence { self.isStatusUnavailable = true }
            }
            if fence == self.latestFence { self.activeReadTask = nil }
        }
        activeReadTask = task
        return task
    }

    private func startWorkIfActive() {
        guard cadence != .released, !suspended, capabilityEnabled, let token = surfaceToken,
              let coordinator = activityCoordinator,
              coordinator.activity(for: token).allowsPresentationPublication,
              profileID != nil, connectionID != nil, fetch != nil else { return }
        if activeReadTask == nil { startRead() }
        if cadence == .mounted { startFallbackLoop() }
    }

    private func startFallbackLoop() {
        guard let token = surfaceToken, let profileID, let connectionID else { return }
        mountedTask?.cancel()
        mountedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.fallbackInterval) }
                catch { return }
                guard !Task.isCancelled,
                      self.surfaceIsActive(token),
                      self.profileID == profileID,
                      self.connectionID == connectionID else { return }
                await self.startRead()?.value
            }
        }
    }

    private func surfaceIsActive(_ token: PresentationSurfaceToken) -> Bool {
        guard token == surfaceToken, let coordinator = activityCoordinator else { return false }
        return PresentationPublicationPolicy.allows(
            ambient: .covered,
            coordinator: coordinator,
            token: token
        )
    }

    private func stopWork(clearStatus: Bool) {
        mountedTask?.cancel()
        mountedTask = nil
        invalidateRead(clearStatus: clearStatus)
    }

    private func invalidateRead(clearStatus: Bool) {
        readGeneration &+= 1
        latestFence = nil
        activeReadTask?.cancel()
        activeReadTask = nil
        if clearStatus {
            status = nil
            isStatusUnavailable = false
        }
    }
}
