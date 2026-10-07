import Foundation
import TronMobileCore

/// Typed subset of the Gateway's complete bounded `home.status` projection.
/// Required structural sections and closed enums make protocol drift fail closed.
struct HomeStatusDTO: Decodable, Equatable, Sendable {
    enum Phase: String, Decodable, Sendable {
        case unavailable, undesignated, disabled, missingSession = "missing-session", blocked, active, ready
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
            if available && activationOpen == nil { throw DecodingError.dataCorruptedError(forKey: .activationOpen, in: values, debugDescription: "Available activation must state whether it is open") }
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
        let blocked: String?
        let reason: String?
    }

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
        guard status.readiness.gaps.count <= 128,
              status.readiness.gaps.allSatisfy({ $0.utf8.count <= 256 }),
              status.generation.map({ $0 >= 0 }) ?? true,
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
    fileprivate let readGeneration: UInt64
    fileprivate let surfaceGeneration: UInt64
}

/// Owns only a disposable Home status projection. The focused profile's caller
/// supplies its authenticated connection and managed surface activity; exact
/// generations prevent stale reads from a replaced connection or retired view.
@MainActor
final class HomeStatusPresentationOwner {
    static let fallbackInterval: Duration = .seconds(5)

    private(set) var status: HomeStatusDTO?
    private var readGeneration: UInt64 = 0
    private var surfaceGeneration: UInt64 = 0
    private var latestFence: HomeStatusReadFence?
    private var admittedIdentity: (profileID: String, connectionID: String)?
    private var mountedRead: (profileID: String, connectionID: String, capabilityEnabled: Bool, fetch: @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO)?
    private var activeReadTask: Task<Void, Never>?
    private var mountedTask: Task<Void, Never>?

    func beginRead(profileID: String, connectionID: String, capabilityEnabled: Bool, presentationActive: Bool) -> HomeStatusReadFence? {
        guard capabilityEnabled, presentationActive, !profileID.isEmpty, !connectionID.isEmpty else {
            invalidateReads(clearStatus: !capabilityEnabled)
            return nil
        }
        if let admittedIdentity,
           admittedIdentity.profileID != profileID || admittedIdentity.connectionID != connectionID {
            status = nil
        }
        admittedIdentity = (profileID, connectionID)
        readGeneration &+= 1
        let fence = HomeStatusReadFence(profileID: profileID, connectionID: connectionID, readGeneration: readGeneration, surfaceGeneration: surfaceGeneration)
        latestFence = fence
        return fence
    }

    @discardableResult
    func publish(_ value: HomeStatusDTO, for fence: HomeStatusReadFence, currentProfileID: String, currentConnectionID: String, presentationActive: Bool) -> Bool {
        guard presentationActive,
              fence.profileID == currentProfileID,
              fence.connectionID == currentConnectionID,
              fence.surfaceGeneration == surfaceGeneration,
              fence == latestFence else { return false }
        status = value
        return true
    }

    func refresh(
        profileID: String,
        connectionID: String,
        capabilityEnabled: Bool,
        presentationActive: Bool,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO
    ) async {
        guard let fence = beginRead(profileID: profileID, connectionID: connectionID, capabilityEnabled: capabilityEnabled, presentationActive: presentationActive) else { return }
        activeReadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            do {
                let value = try await fetch(fence)
                guard !Task.isCancelled, let self else { return }
                _ = self.publish(value, for: fence, currentProfileID: profileID, currentConnectionID: connectionID, presentationActive: presentationActive)
            } catch {
                // Status is disposable; keep its last projection and allow the
                // next event or mounted fallback to retry.
            }
        }
        activeReadTask = task
        await task.value
        if fence == latestFence { activeReadTask = nil }
    }

    func mountFallback(
        profileID: String,
        connectionID: String,
        capabilityEnabled: Bool,
        presentationActive: Bool,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO
    ) {
        mountedTask?.cancel()
        guard capabilityEnabled else {
            mountedRead = nil
            admittedIdentity = nil
            invalidateReads(clearStatus: true)
            return
        }
        guard Self.shouldRefreshForInvalidation(isMounted: true, isForeground: presentationActive) else {
            mountedRead = nil
            admittedIdentity = nil
            invalidateReads(clearStatus: true)
            return
        }
        mountedRead = (profileID, connectionID, capabilityEnabled, fetch)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.invalidateMounted(presentationActive: presentationActive)
        }
        mountedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.fallbackInterval) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self.refresh(profileID: profileID, connectionID: connectionID, capabilityEnabled: capabilityEnabled, presentationActive: presentationActive, fetch: fetch)
            }
        }
    }

    /// Session summaries/activity, route entry, and accepted mutation completion
    /// call this edge-triggered path; it never waits for the fallback cadence.
    func invalidateMounted(sessionID: String? = nil, presentationActive: Bool) async {
        guard presentationActive, let mountedRead,
              sessionID == nil || status?.sessionId == sessionID else { return }
        await refresh(profileID: mountedRead.profileID, connectionID: mountedRead.connectionID, capabilityEnabled: mountedRead.capabilityEnabled, presentationActive: true, fetch: mountedRead.fetch)
    }

    func retireSurface() {
        surfaceGeneration &+= 1
        mountedRead = nil
        mountedTask?.cancel()
        mountedTask = nil
        activeReadTask?.cancel()
        activeReadTask = nil
        admittedIdentity = nil
        invalidateReads(clearStatus: true)
    }

    static func shouldRefreshForInvalidation(isMounted: Bool, isForeground: Bool) -> Bool {
        isMounted && isForeground
    }

    private func invalidateReads(clearStatus: Bool) {
        activeReadTask?.cancel()
        activeReadTask = nil
        readGeneration &+= 1
        latestFence = nil
        if clearStatus { status = nil }
    }
}
