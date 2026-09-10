import Foundation

/// The trusted host binds these identities to a live process, window and session. IDs
/// are correlation data, not permission: a live backend must validate the binding.
internal struct NativeControlTargetBinding: Hashable, Sendable {
    let targetID: UUID
    let processGeneration: UInt64
    let windowGeneration: UInt64
    let sessionGeneration: UInt64

    internal init(targetID: UUID = UUID(), processGeneration: UInt64,
                  windowGeneration: UInt64, sessionGeneration: UInt64) {
        self.targetID = targetID
        self.processGeneration = processGeneration
        self.windowGeneration = windowGeneration
        self.sessionGeneration = sessionGeneration
    }
}

/// A scope is source-bound to the signed host which granted it. The owner never
/// accepts a model supplied Boolean as evidence of this binding.
internal struct NativeControlScopeBinding: Hashable, Sendable {
    let scopeID: UUID
    let sourceID: UUID
    let generation: UInt64

    internal init(scopeID: UUID = UUID(), sourceID: UUID, generation: UInt64) {
        self.scopeID = scopeID
        self.sourceID = sourceID
        self.generation = generation
    }
}

internal struct NativeInputEventTicket: Equatable, Hashable, Sendable {
    let operationID: UUID
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let eventOrdinal: Int
    let sequence: UInt64
}

internal struct NativeFocusEffectTicket: Equatable, Sendable {
    let operationID: UUID
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
}

/// A live query of owner admission, not native-release evidence. The backend
/// rechecks this after its own preparation, immediately before native dispatch.
internal struct NativeInputAdmission: Sendable {
    private let check: @Sendable () -> Bool
    init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
    var allowsDispatch: Bool { check() }
}

internal struct NativeDispatchRequest: @unchecked Sendable {
    let ticket: NativeInputEventTicket
    let event: ConstructedInputEvent
    let admission: NativeInputAdmission
}

internal struct NativeDispatchAcknowledgement: Equatable, Sendable {
    let ticket: NativeInputEventTicket
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let backendSequence: UInt64
}

internal enum NativeDispatchOutcome: Sendable {
    /// The backend proves that no native dispatch occurred. This is not an
    /// invitation to retry: a ticket is attempted at most once.
    case notDispatched(String)
    case accepted(NativeDispatchAcknowledgement)
    /// The backend cannot say whether the event reached the OS. The owner keeps
    /// the prefix unresolved and never sends this ticket again.
    case uncertain(String)
}

internal enum NativeObservedTransition: Equatable, Sendable {
    case down(HeldInputIdentity)
    case up(HeldInputIdentity)
    case none
}

internal struct NativeInputObservation: Equatable, Sendable {
    let ticket: NativeInputEventTicket
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let backendSequence: UInt64
    let transition: NativeObservedTransition
}

internal enum NativeObservationOutcome: Sendable {
    case observed(NativeInputObservation)
    case unavailable(String)
}

internal struct NativeFocusEffectObservation: Equatable, Sendable {
    let ticket: NativeFocusEffectTicket
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let backendSequence: UInt64
}

internal struct NativePreparationEvidence: Equatable, Sendable {
    let operationID: UUID
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let backendSequence: UInt64
    let focus: NativeFocusEffectObservation?
}

internal enum NativePreparationOutcome: Sendable {
    case ready(NativePreparationEvidence)
    /// No focus or input mutation was performed.
    case notPrepared(String)
    /// Preparation may have crossed the native boundary; recovery must prove
    /// what happened before the marker can be retired.
    case uncertain(String)
}

internal struct NativeQuiescenceRequest: Equatable, Sendable {
    let operationID: UUID
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let uncertainEventOrdinals: [Int]
    let pendingResourceOpeningOrdinals: [Int]
    let focusUncertain: Bool
    let scopeRevoked: Bool
    let controlRevision: UInt64
}

internal struct NativeQuiescenceEvidence: Equatable, Sendable {
    let operationID: UUID
    let target: NativeControlTargetBinding
    let scope: NativeControlScopeBinding
    let backendSequence: UInt64
    let resolvedEventOrdinals: [Int]
    let releasedResourceOpeningOrdinals: [Int]
    let focusResolved: Bool
    let scopeRevoked: Bool
    let controlRevision: UInt64
}

internal enum NativeQuiescenceOutcome: Sendable {
    case quiescent(NativeQuiescenceEvidence)
    case unavailable(String)
}

internal typealias NativeRecoveryRequest = NativeQuiescenceRequest
internal typealias NativeRecoveryOutcome = NativeQuiescenceOutcome

/// This is the sole I/O boundary. There is intentionally no production
/// implementation in this package. A signed host must implement every method
/// with actual target/grant/session binding and native event observations.
internal protocol NativeInputIO: Sendable {
    func prepare(operationID: UUID, target: NativeControlTargetBinding,
                 scope: NativeControlScopeBinding, admission: NativeInputAdmission) async -> NativePreparationOutcome
    func dispatch(_ request: NativeDispatchRequest) async -> NativeDispatchOutcome
    func observe(_ ticket: NativeInputEventTicket,
                 after acknowledgement: NativeDispatchAcknowledgement) async -> NativeObservationOutcome
    func quiescence(_ request: NativeQuiescenceRequest) async -> NativeQuiescenceOutcome
    func recover(_ request: NativeRecoveryRequest) async -> NativeRecoveryOutcome
}

internal enum NativeOperationStatus: Equatable, Sendable {
    case preparing
    case running
    case waitingDelay
    case stopping
    case needsRecovery
    case settled
}

internal enum NativeOperationCompletion: Equatable, Sendable {
    case completed
    case stopped
    case failed(String)
}

internal struct NativeOperationAccounting: Equatable, Sendable {
    let attemptedEventOrdinals: [Int]
    let acceptedEventOrdinals: [Int]
    let observedEventOrdinals: [Int]
    let focusEffectsAttempted: Int
    let focusEffectsAccepted: Int
    let focusEffectsObserved: Int
    let heldOpeningOrdinals: [Int]
}

internal struct NativeOperationReport: Equatable, Sendable {
    let operationID: UUID
    let outcome: NativeOperationCompletion
    let accounting: NativeOperationAccounting
}

internal struct NativeOperationSnapshot: Equatable, Sendable {
    let status: NativeOperationStatus
    let accounting: NativeOperationAccounting
}

internal final class NativeRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NativeQuiescenceEvidence, Never>?
    private var offered: NativeQuiescenceEvidence?

    func wait() async -> NativeQuiescenceEvidence {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let offered {
                self.offered = nil
                lock.unlock()
                continuation.resume(returning: offered)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func offer(_ evidence: NativeQuiescenceEvidence) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: evidence)
        } else {
            // There is only one recovery slot. A later authoritative answer
            // supersedes an answer that arrived before the owner needed it.
            offered = evidence
            lock.unlock()
        }
    }
}

internal enum NativeOwnerFailure: Error, CustomStringConvertible {
    case rejected(String)
    case evidence(String)

    var description: String {
        switch self {
        case let .rejected(reason): "native input rejected: \(reason)"
        case let .evidence(reason): "native input evidence rejected: \(reason)"
        }
    }
}
