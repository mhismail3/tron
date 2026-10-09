import Foundation
import Observation
import TronMobileCore

/// Typed subset of the Gateway's complete bounded `home.status` projection.
/// Required structural sections and closed enums make protocol drift fail closed.
struct HomeStatusDTO: Decodable, Equatable, Sendable {
    enum Phase: String, Decodable, Sendable {
        case unavailable, undesignated, disabled, missingSession = "missing-session"
        case rolloverPending = "rollover-pending", blocked, paused, active, ready
    }

    struct Activation: Decodable, Equatable, Sendable {
        let available: Bool
        let activationStartEntryId: String?
        let activationOpen: Bool?
        let viewLines: Int?
        let viewBytes: Int?
        let effectiveTokens: Int?
        let contextWindow: Int?
        let lastRefusalReason: String?
        let lastRefusalDetail: String?

        private enum CodingKeys: String, CodingKey {
            case available, activationStartEntryId, activationOpen, viewLines, viewBytes
            case effectiveTokens, contextWindow, lastRefusalReason, lastRefusalDetail
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            available = try values.decode(Bool.self, forKey: .available)
            activationStartEntryId = try values.decodeIfPresent(String.self, forKey: .activationStartEntryId)
            activationOpen = try values.decodeIfPresent(Bool.self, forKey: .activationOpen)
            viewLines = try values.decodeIfPresent(Int.self, forKey: .viewLines)
            viewBytes = try values.decodeIfPresent(Int.self, forKey: .viewBytes)
            effectiveTokens = try values.decodeIfPresent(Int.self, forKey: .effectiveTokens)
            contextWindow = try values.decodeIfPresent(Int.self, forKey: .contextWindow)
            lastRefusalReason = try values.decodeIfPresent(String.self, forKey: .lastRefusalReason)
            lastRefusalDetail = try values.decodeIfPresent(String.self, forKey: .lastRefusalDetail)
            if available && activationOpen == nil {
                throw DecodingError.dataCorruptedError(forKey: .activationOpen, in: values, debugDescription: "Available activation must state whether it is open")
            }
        }
    }

    struct Readiness: Decodable, Equatable, Sendable {
        let ready: Bool
        let gaps: [String]
    }

    struct Recovery: Decodable, Equatable, Sendable {
        enum Action: String, Decodable, Sendable {
            case inspectRecord = "inspect-record", designate, configureMemory = "configure-memory", resumeMemory = "resume-memory", none
        }
        let action: Action
        let reason: String?
    }

    struct Memory: Decodable, Equatable, Sendable {
        let configured: Bool
        let open: Bool
        let paused: Bool?
        let blocked: String?
        let reason: String?
        let model: ModelRef?
        let spentTokens: Int?
    }

    struct TaskRecovery: Decodable, Equatable, Sendable {
        let available: Bool
        let reason: String?
    }
    let taskRecovery: TaskRecovery?
    let routeGeneration: Int?
    let phase: Phase
    let activation: Activation
    let readiness: Readiness
    let recovery: Recovery
    let available: Bool
    let reason: String?
    let enabled: Bool
    let homeId: String?
    let sessionId: String?
    /// The newest chapter a client may open; the sealed predecessor while a
    /// rollover is pending. Nil when nothing is openable.
    let openSessionId: String?
    let generation: Int?
    let live: Bool
    let sessionPresent: Bool
    let memory: Memory

    static func decode(_ value: JSONValue) throws -> HomeStatusDTO {
        let status = try JSONDecoder().decode(HomeStatusDTO.self, from: JSONEncoder().encode(value))
        guard status.taskRecovery.map({ $0.available || ($0.reason.map { !$0.isEmpty && $0.utf8.count <= 1024 } ?? false) }) ?? true,
              status.routeGeneration.map({ $0 > 0 }) ?? true,
              status.readiness.gaps.count <= 128,
              status.readiness.gaps.allSatisfy({ $0.utf8.count <= 256 }),
              status.generation.map({ $0 >= 0 }) ?? true,
              status.memory.spentTokens.map({ $0 >= 0 }) ?? true,
              status.memory.model.map({ !$0.provider.isEmpty && !$0.id.isEmpty && $0.provider.utf8.count <= 120 && $0.id.utf8.count <= 300 }) ?? true,
              [status.reason, status.recovery.reason, status.memory.blocked, status.memory.reason,
               status.activation.lastRefusalReason, status.activation.lastRefusalDetail]
                .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 1_024 }),
              [status.homeId, status.sessionId, status.openSessionId, status.activation.activationStartEntryId]
                .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              [status.activation.viewLines, status.activation.viewBytes, status.activation.effectiveTokens, status.activation.contextWindow]
                .compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Home status exceeds protocol bounds"))
        }
        return status
    }
}

/// The chat route that a status claim and the Home header both decide for. A
/// Home route always presents Home, even when no chapter is openable, so its
/// recovery state stays visible. An ordinary chat presents only the chapter it
/// is (`sessionId`), so an ordinary chat on the sealed predecessor during a
/// rollover neither claims the status nor shows the header.
enum HomeChatRouteKey: Equatable, Sendable {
    case home
    case ordinary(sessionID: String)

    static func forChat(sessionID: String, isHome: Bool) -> HomeChatRouteKey {
        isHome ? .home : .ordinary(sessionID: sessionID)
    }

    func matches(_ status: HomeStatusDTO) -> Bool {
        switch self {
        case .home: true
        case .ordinary(let sessionID): status.sessionId == sessionID
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

/// Owns a disposable focused-profile status projection. A read is valid only
/// while its exact managed surface and authenticated connection are current.
@MainActor
@Observable
final class HomeStatusPresentationOwner {
    static let fallbackInterval: Duration = .seconds(5)

    private(set) var status: HomeStatusDTO?
    /// The latest read reached a Gateway whose status this client could not read
    /// or admit. It is cleared with the status and by the next publication.
    private(set) var isStatusUnavailable = false
    var isCapabilityEnabled: Bool { capabilityEnabled }
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private var surfaceGeneration: UInt64 = 0
    @ObservationIgnored private var latestFence: HomeStatusReadFence?
    @ObservationIgnored private(set) var surfaceToken: PresentationSurfaceToken?
    @ObservationIgnored private weak var activityCoordinator: PresentationActivityCoordinator?
    @ObservationIgnored private var profileID: String?
    @ObservationIgnored private var connectionID: String?
    private(set) var capabilityEnabled = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var fetch: (@MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO)?
    @ObservationIgnored private var activeReadTask: Task<Void, Never>?
    @ObservationIgnored private var mountedTask: Task<Void, Never>?

    /// `mounted` follows the visible Home surface: a fallback cadence, immediate
    /// invalidation, and mutation refresh. `connectionOnly` is a chat's probe for a
    /// status it could not yet know: it reads on connection admission and, once
    /// per claim, after a covering discarded its read. Its first publication decides
    /// the claim by its `HomeChatRouteKey`: a match promotes it to `mounted`; a miss
    /// moves it to `released`, which keeps the published status but never reads again.
    enum Cadence: Equatable, Sendable {
        case mounted
        case connectionOnly(HomeChatRouteKey)
        case released
    }
    /// Chosen at mount: a claim is a property of the surface that takes the status.
    @ObservationIgnored private var cadence = Cadence.mounted
    @ObservationIgnored private var claimCoverRetryUsed = false

    /// Replacing a mount creates a new authority. A late retirement callback for
    /// the prior token is intentionally a no-op. The surface owns the read, so a
    /// mount before pairing (no selected profile yet) can still read once a
    /// profile is configured.
    func mountSurface(
        token: PresentationSurfaceToken,
        coordinator: PresentationActivityCoordinator,
        cadence: Cadence = .mounted,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO
    ) {
        guard token != surfaceToken || activityCoordinator !== coordinator else { return }
        stopWork(clearStatus: true)
        surfaceGeneration &+= 1
        surfaceToken = token
        activityCoordinator = coordinator
        self.fetch = fetch
        self.cadence = cadence
        claimCoverRetryUsed = false
        profileID = nil
        connectionID = nil
        capabilityEnabled = false
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

    /// Lifecycle retirement drops connection-scoped data, but keeps the exact
    /// visible surface so an authenticated reconnect can install a new admission.
    /// The capability survives: a reconnect to the same profile must not flicker.
    func connectionRetired() {
        connectionID = nil
        stopWork(clearStatus: true)
    }

    /// A profile transition forgets what the previous profile advertised.
    func profileRetired() {
        profileID = nil
        connectionID = nil
        capabilityEnabled = false
        stopWork(clearStatus: true)
    }

    /// Called only after the lifecycle has admitted a fresh authenticated hello.
    func connectionAvailable(profileID: String, connectionID: String, capabilityEnabled: Bool) {
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

    /// Presentation coordinator changes are re-evaluated at the same owner
    /// boundary as reads, rather than trusting an activity Boolean captured earlier.
    /// A covering discards a claim's in-flight read; the first uncover of that claim
    /// retries it once, so a sheet cannot leave the chat header unresolved forever.
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

    /// A session-scoped invalidation names a Home chapter: the one a route opens
    /// (`openSessionId`, the sealed predecessor during a rollover) or the reserved
    /// `sessionId`. Both are Home's sessions, so either refreshes the projection.
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
    func publish(_ value: HomeStatusDTO, for fence: HomeStatusReadFence) -> Bool {
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
        stopWork(clearStatus: true)
        surfaceGeneration &+= 1
        surfaceToken = nil
        activityCoordinator = nil
        profileID = nil
        connectionID = nil
        capabilityEnabled = false
        fetch = nil
        suspended = false
    }

    /// Backgrounding suspends disposable presentation work but retains the route
    /// token for foreground reconciliation if SwiftUI keeps that route mounted.
    func suspendForBackground() {
        suspended = true
        stopWork(clearStatus: true)
    }

    /// A claim's first publication decides it, by the same `HomeChatRouteKey` the
    /// chat's header uses. A matching route promotes the surface to the mounted
    /// cadence without an extra read. Any other route releases it and stops every
    /// read, while the published status stays for the dashboard.
    private func resolveClaim(with value: HomeStatusDTO) {
        guard case .connectionOnly(let claim) = cadence else { return }
        if claim.matches(value) {
            cadence = .mounted
            startFallbackLoop()
        } else {
            cadence = .released
            stopWork(clearStatus: false)
        }
    }

    /// Starts the surface's read for its current identity. The fence is captured
    /// when the read starts, so it is bound to the surface, profile and connection
    /// current at that moment. A new read supersedes the one in flight.
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
                // A superseded or retired read is not an answer from the Gateway.
            } catch {
                // Status is disposable: the next event or mounted fallback retries.
                // The row must still say why it has no status, not keep loading.
                if !Task.isCancelled, fence == self.latestFence { self.isStatusUnavailable = true }
            }
            // The handle is the single in-flight read; a read that is still the latest
            // when it settles releases it, so the next start is not blocked.
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
        // Configuration and presentation both reach here for one mount, in the same
        // turn. The read already in flight serves that start, so a second one is not
        // started: two reads would cancel each other after the first had fetched.
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

    /// Invalidating a read cancels it: an invalidated read has no fence left to
    /// publish under, so its request is no longer wanted.
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
