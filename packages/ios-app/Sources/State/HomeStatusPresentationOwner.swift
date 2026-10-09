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
              [status.homeId, status.sessionId, status.activation.activationStartEntryId]
                .compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              [status.activation.viewLines, status.activation.viewBytes, status.activation.effectiveTokens, status.activation.contextWindow]
                .compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Home status exceeds protocol bounds"))
        }
        return status
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

    /// Replacing a mount creates a new authority. A late retirement callback for
    /// the prior token is intentionally a no-op.
    func mountSurface(token: PresentationSurfaceToken, coordinator: PresentationActivityCoordinator) {
        guard token != surfaceToken || activityCoordinator !== coordinator else { return }
        stopWork(clearStatus: true)
        surfaceGeneration &+= 1
        surfaceToken = token
        activityCoordinator = coordinator
        profileID = nil
        connectionID = nil
        capabilityEnabled = false
        fetch = nil
        suspended = false
    }

    func configure(
        profileID: String,
        connectionID: String?,
        capabilityEnabled: Bool,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO
    ) {
        let identityChanged = self.profileID != profileID || self.connectionID != connectionID
        if identityChanged { stopWork(clearStatus: true) }
        self.profileID = profileID
        self.connectionID = connectionID
        self.capabilityEnabled = capabilityEnabled
        self.fetch = fetch
        suspended = false
        guard capabilityEnabled else {
            stopWork(clearStatus: true)
            return
        }
        startWorkIfActive()
    }

    /// Lifecycle retirement drops connection-scoped data, but keeps the exact
    /// visible surface so an authenticated reconnect can install a new admission.
    func connectionRetired() {
        connectionID = nil
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
    func presentationActivityChanged(for token: PresentationSurfaceToken) {
        guard token == surfaceToken else { return }
        guard surfaceIsActive(token) else {
            stopWork(clearStatus: false)
            return
        }
        startWorkIfActive()
    }

    func invalidateMounted(sessionID: String? = nil) async {
        guard sessionID == nil || status?.sessionId == sessionID else { return }
        await refreshMounted()
    }

    func refreshMounted() async {
        guard !suspended,
              capabilityEnabled,
              let profileID, let connectionID,
              let token = surfaceToken,
              let coordinator = activityCoordinator,
              let fetch,
              surfaceIsActive(token) else { return }
        await refresh(
            profileID: profileID,
            connectionID: connectionID,
            capabilityEnabled: capabilityEnabled,
            token: token,
            coordinator: coordinator,
            fetch: fetch
        )
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
        if self.profileID != profileID || self.connectionID != connectionID { status = nil }
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

    private func refresh(
        profileID: String,
        connectionID: String,
        capabilityEnabled: Bool,
        token: PresentationSurfaceToken,
        coordinator: PresentationActivityCoordinator,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO
    ) async {
        guard let fence = beginRead(
            profileID: profileID,
            connectionID: connectionID,
            capabilityEnabled: capabilityEnabled,
            token: token,
            coordinator: coordinator
        ) else { return }
        activeReadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            do {
                let value = try await fetch(fence)
                guard !Task.isCancelled, let self else { return }
                _ = self.publish(value, for: fence)
            } catch {
                // Status is disposable; keep its last projection and allow the
                // next event or mounted fallback to retry.
            }
        }
        activeReadTask = task
        await task.value
        if fence == latestFence { activeReadTask = nil }
    }

    private func startWorkIfActive() {
        guard !suspended, capabilityEnabled, let token = surfaceToken,
              let coordinator = activityCoordinator,
              coordinator.activity(for: token).allowsPresentationPublication,
              let profileID, let connectionID, let fetch else { return }
        mountedTask?.cancel()
        Task { @MainActor [weak self] in await self?.refreshMounted() }
        mountedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.fallbackInterval) }
                catch { return }
                guard !Task.isCancelled,
                      self.surfaceIsActive(token),
                      self.profileID == profileID,
                      self.connectionID == connectionID else { return }
                await self.refresh(
                    profileID: profileID,
                    connectionID: connectionID,
                    capabilityEnabled: true,
                    token: token,
                    coordinator: coordinator,
                    fetch: fetch
                )
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
        activeReadTask?.cancel()
        activeReadTask = nil
        invalidateRead(clearStatus: clearStatus)
    }

    private func invalidateRead(clearStatus: Bool) {
        readGeneration &+= 1
        latestFence = nil
        if clearStatus { status = nil }
    }
}
