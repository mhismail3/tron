struct TerminalPresentationTarget: Hashable, Sendable {
    let sessionID: String
    let generation: Int
}

struct TerminalPresentationIntent: Hashable, Sendable {
    let presentation: TerminalPresentationTarget
    let generation: Int
}

struct TerminalReplayProjection: Equatable, Sendable {
    let chunks: [TerminalChunk]
    let revision: Int

    static let empty = TerminalReplayProjection(chunks: [], revision: 0)
}

struct TerminalRendererIdentity: Hashable, Sendable {
    let terminalID: String
    let replayRevision: Int
}

struct TerminalAttachmentLease: Equatable, Sendable {
    let intent: TerminalPresentationIntent
    let requestedTerminalID: String?
    let operationGeneration: Int
    let connectionID: Int
    let quarantineGeneration: Int
}

struct TerminalDetachClaim: Hashable, Sendable {
    let terminalID: String
    let connectionID: Int
}

enum TerminalOpenResponseDisposition: Equatable, Sendable {
    case install
    case reattach
    case discard
}

enum TerminalOutputAdmission: Equatable, Sendable {
    case ignored
    case buffered
    case appended
    case gap(after: Int)
}

enum TerminalEventReduction: Equatable, Sendable {
    case none
    case reconcile(terminalID: String)
}

struct TerminalReplayInstallation: Equatable, Sendable {
    let admittedCount: Int
    let requiresReconciliation: Bool
}

struct TerminalReducer {
    static func openResponseDisposition(
        requestLifecycleGeneration: Int,
        requestConnectionID: Int,
        currentLifecycleGeneration: Int?,
        currentConnectionID: Int?
    ) -> TerminalOpenResponseDisposition {
        guard currentLifecycleGeneration == requestLifecycleGeneration,
              let currentConnectionID else { return .discard }
        return currentConnectionID == requestConnectionID ? .install : .reattach
    }

    private struct OperationKey: Hashable, Sendable {
        let terminalID: String
        let intent: TerminalPresentationIntent
    }

    private struct PendingEvents: Sendable {
        var outputBySequence: [Int: TerminalChunk] = [:]
        var outputBytes = 0
        var exit: (sequence: Int?, code: Int?, date: String)?
        var requiresReconciliation = false
    }

    private static let maximumPendingTerminalCount = 16
    private static let maximumPendingOutputCount = 256
    private static let maximumPendingOutputBytes = 1_048_576
    private static let maximumReplayOutputCount = 2_048
    private static let maximumReplayOutputBytes = 768 * 1_024
    private static let maximumImmediateRecoveryAttempts = 3

    private var nextPresentationGeneration = 0
    private var nextIntentGeneration = 0
    private var nextOperationGeneration = 0
    private var presentations: Set<TerminalPresentationTarget> = []
    private var activeIntentByPresentation: [TerminalPresentationTarget: TerminalPresentationIntent] = [:]
    private var operationByKey: [OperationKey: TerminalAttachmentLease] = [:]
    private var openOperationByIntent: [TerminalPresentationIntent: TerminalAttachmentLease] = [:]
    private var attachmentOwnersByTerminalID: [String: [TerminalPresentationIntent: Int]] = [:]
    private var lastInstalledOperationByTerminalID: [String: Int] = [:]
    private var pendingEventsByTerminalID: [String: PendingEvents] = [:]
    private var pendingOverflowGeneration = 0
    private var immediateRecoveryAttemptsByTerminalID: [String: Int] = [:]
    private var reconcilingTerminalIDs: Set<String> = []
    private var terminalIDsBySession: [String: Set<String>] = [:]
    private var replayByID: [String: TerminalReplayProjection] = [:]
    // Replay output is bounded and may retain only a suffix. Keep the highest
    // sequence proven contiguous separately so admission never infers a cursor
    // from a truncated projection.
    private var lastProvenSequenceByTerminalID: [String: Int] = [:]
    private var exitedTerminalIDs: Set<String> = []

    mutating func beginPresentation(sessionID: String) -> TerminalPresentationTarget {
        nextPresentationGeneration &+= 1
        let target = TerminalPresentationTarget(
            sessionID: sessionID,
            generation: nextPresentationGeneration
        )
        presentations.insert(target)
        return target
    }

    mutating func beginIntent(
        for target: TerminalPresentationTarget
    ) -> (intent: TerminalPresentationIntent, detached: [TerminalDetachClaim])? {
        guard presentations.contains(target) else { return nil }
        nextIntentGeneration &+= 1
        let intent = TerminalPresentationIntent(
            presentation: target,
            generation: nextIntentGeneration
        )
        let detached = invalidateWork(for: target)
        activeIntentByPresentation[target] = intent
        return (intent, detached)
    }

    mutating func revokePresentation(_ target: TerminalPresentationTarget) -> [TerminalDetachClaim] {
        guard presentations.remove(target) != nil else { return [] }
        activeIntentByPresentation.removeValue(forKey: target)
        return invalidateWork(for: target)
    }

    func owns(_ intent: TerminalPresentationIntent) -> Bool {
        presentations.contains(intent.presentation)
            && activeIntentByPresentation[intent.presentation] == intent
    }

    mutating func beginOpen(
        intent: TerminalPresentationIntent,
        connectionID: Int
    ) -> TerminalAttachmentLease? {
        guard owns(intent) else { return nil }
        nextOperationGeneration &+= 1
        let lease = TerminalAttachmentLease(
            intent: intent,
            requestedTerminalID: nil,
            operationGeneration: nextOperationGeneration,
            connectionID: connectionID,
            quarantineGeneration: pendingOverflowGeneration
        )
        openOperationByIntent[intent] = lease
        return lease
    }

    mutating func beginAttachment(
        terminalID: String,
        intent: TerminalPresentationIntent,
        connectionID: Int,
        reconciling: Bool = false
    ) -> TerminalAttachmentLease? {
        guard owns(intent) else { return nil }
        if reconciling, reconcilingTerminalIDs.contains(terminalID) { return nil }
        if !reconciling { immediateRecoveryAttemptsByTerminalID.removeValue(forKey: terminalID) }
        nextOperationGeneration &+= 1
        let lease = TerminalAttachmentLease(
            intent: intent,
            requestedTerminalID: terminalID,
            operationGeneration: nextOperationGeneration,
            connectionID: connectionID,
            quarantineGeneration: pendingOverflowGeneration
        )
        operationByKey[OperationKey(terminalID: terminalID, intent: intent)] = lease
        if reconciling { reconcilingTerminalIDs.insert(terminalID) }
        return lease
    }

    mutating func beginReattachment(
        terminalID: String,
        connectionID: Int
    ) -> TerminalAttachmentLease? {
        guard let intent = attachmentOwnersByTerminalID[terminalID]?.keys.first(where: owns) else {
            return nil
        }
        reconcilingTerminalIDs.remove(terminalID)
        return beginAttachment(
            terminalID: terminalID,
            intent: intent,
            connectionID: connectionID
        )
    }

    mutating func beginReconciliation(
        terminalID: String,
        connectionID: Int
    ) -> TerminalAttachmentLease? {
        let attempts = immediateRecoveryAttemptsByTerminalID[terminalID] ?? 0
        guard attempts < Self.maximumImmediateRecoveryAttempts,
              !operationByKey.keys.contains(where: { $0.terminalID == terminalID }),
              let intent = attachmentOwnersByTerminalID[terminalID]?.first(where: {
                $0.value == connectionID && owns($0.key)
              })?.key,
              let lease = beginAttachment(
                terminalID: terminalID,
                intent: intent,
                connectionID: connectionID,
                reconciling: true
              ) else { return nil }
        immediateRecoveryAttemptsByTerminalID[terminalID] = attempts + 1
        return lease
    }

    func admits(
        _ lease: TerminalAttachmentLease,
        returnedTerminalID: String
    ) -> Bool {
        guard owns(lease.intent),
              lease.requestedTerminalID == nil || lease.requestedTerminalID == returnedTerminalID
        else { return false }
        if let requestedTerminalID = lease.requestedTerminalID {
            return operationByKey[OperationKey(
                terminalID: requestedTerminalID,
                intent: lease.intent
            )] == lease
        }
        return openOperationByIntent[lease.intent] == lease
    }

    @discardableResult
    mutating func installReplay(
        _ chunks: [TerminalChunk],
        terminal: TerminalSummary,
        reset: Bool,
        after: Int,
        lease: TerminalAttachmentLease
    ) -> TerminalReplayInstallation? {
        guard terminal.sessionId == lease.intent.presentation.sessionID,
              admits(lease, returnedTerminalID: terminal.id) else { return nil }
        let lastInstalled = lastInstalledOperationByTerminalID[terminal.id] ?? 0
        // A response from an older operation is rejected before consuming its
        // operation or changing ownership/replay state. Callers must treat nil
        // as a stale attach failure, not as a successful zero-byte install.
        guard lease.operationGeneration >= lastInstalled else { return nil }

        let operationKey = OperationKey(terminalID: terminal.id, intent: lease.intent)
        operationByKey.removeValue(forKey: operationKey)
        openOperationByIntent.removeValue(forKey: lease.intent)
        reconcilingTerminalIDs.remove(terminal.id)

        var owners = attachmentOwnersByTerminalID[terminal.id] ?? [:]
        owners = owners.filter { owns($0.key) }
        for intent in owners.keys { owners[intent] = lease.connectionID }
        owners[lease.intent] = lease.connectionID
        attachmentOwnersByTerminalID[terminal.id] = owners

        lastInstalledOperationByTerminalID[terminal.id] = lease.operationGeneration

        let current = replayByID[terminal.id] ?? .empty
        let latest = lastProvenSequenceByTerminalID[terminal.id]
            ?? current.chunks.last?.sequence
            ?? after
        let expectedFirst = max(latest, after) + 1
        var admitted: [TerminalChunk] = []
        var nextSequence: Int?
        var requiresReconciliation = false
        for chunk in chunks {
            if let nextSequence {
                guard chunk.sequence == nextSequence else {
                    requiresReconciliation = true
                    break
                }
            } else if !reset {
                guard chunk.sequence == expectedFirst else {
                    requiresReconciliation = true
                    break
                }
            }
            admitted.append(chunk)
            nextSequence = chunk.sequence + 1
        }
        if admitted.count != chunks.count { requiresReconciliation = true }
        if let last = admitted.last?.sequence {
            lastProvenSequenceByTerminalID[terminal.id] = last
        } else if reset {
            lastProvenSequenceByTerminalID[terminal.id] = after
        }
        replayByID[terminal.id] = TerminalReplayProjection(
            chunks: Self.boundedReplay(reset ? admitted : current.chunks + admitted),
            revision: current.revision &+ (reset ? 1 : 0)
        )
        terminalIDsBySession[terminal.sessionId, default: []].insert(terminal.id)
        if terminal.exitedAt == nil { exitedTerminalIDs.remove(terminal.id) }
        else { exitedTerminalIDs.insert(terminal.id) }
        let pending = drainPendingEvents(terminalID: terminal.id)
        pruneUnownedPendingEvents()
        let provenSequence = lastProvenSequenceByTerminalID[terminal.id]
            ?? after
        requiresReconciliation = requiresReconciliation
            || terminal.sequence > provenSequence
            || pending.requiresReconciliation
            || pendingOverflowGeneration > lease.quarantineGeneration
        if !requiresReconciliation {
            immediateRecoveryAttemptsByTerminalID.removeValue(forKey: terminal.id)
        }
        return TerminalReplayInstallation(
            admittedCount: admitted.count + pending.admittedCount,
            requiresReconciliation: requiresReconciliation
        )
    }

    mutating func finish(_ lease: TerminalAttachmentLease) {
        guard let terminalID = lease.requestedTerminalID else {
            if openOperationByIntent[lease.intent] == lease {
                openOperationByIntent.removeValue(forKey: lease.intent)
                pruneUnownedPendingEvents()
            }
            return
        }
        let key = OperationKey(terminalID: terminalID, intent: lease.intent)
        guard operationByKey[key] == lease else { return }
        operationByKey.removeValue(forKey: key)
        reconcilingTerminalIDs.remove(terminalID)
    }

    func hasCurrentInterest(
        in terminalID: String,
        connectionID: Int
    ) -> Bool {
        if attachmentOwnersByTerminalID[terminalID]?.contains(where: {
            $0.value == connectionID && owns($0.key)
        }) == true {
            return true
        }
        return hasPendingAttachmentOperation(
            in: terminalID,
            connectionID: connectionID
        )
    }

    mutating func installInventory(_ terminals: [TerminalSummary], sessionID: String) {
        let returned = terminals.filter { $0.sessionId == sessionID }
        let returnedIDs = Set(returned.map(\.id))
        let priorIDs = terminalIDsBySession[sessionID] ?? []
        for id in priorIDs.subtracting(returnedIDs) {
            replayByID.removeValue(forKey: id)
            lastInstalledOperationByTerminalID.removeValue(forKey: id)
            lastProvenSequenceByTerminalID.removeValue(forKey: id)
            exitedTerminalIDs.remove(id)
            pendingEventsByTerminalID.removeValue(forKey: id)
            attachmentOwnersByTerminalID.removeValue(forKey: id)
            immediateRecoveryAttemptsByTerminalID.removeValue(forKey: id)
            reconcilingTerminalIDs.remove(id)
            operationByKey = operationByKey.filter { $0.key.terminalID != id }
        }
        if returnedIDs.isEmpty { terminalIDsBySession.removeValue(forKey: sessionID) }
        else { terminalIDsBySession[sessionID] = returnedIDs }
        for terminal in returned {
            if terminal.exitedAt == nil { exitedTerminalIDs.remove(terminal.id) }
            else { exitedTerminalIDs.insert(terminal.id) }
        }
    }

    func replay(for terminalID: String) -> TerminalReplayProjection {
        replayByID[terminalID] ?? .empty
    }

    func hasExited(_ terminalID: String) -> Bool {
        exitedTerminalIDs.contains(terminalID)
    }

    mutating func confirmTermination(_ terminalID: String) {
        // terminal.terminate now resolves only after the Gateway has observed
        // canonical PTY exit. This receipt safely closes the UI race even when
        // the preceding terminal.exit event was lost during reconnect.
        exitedTerminalIDs.insert(terminalID)
    }

    func requiresReconciliation(_ terminalID: String) -> Bool {
        pendingEventsByTerminalID[terminalID]?.outputBySequence.isEmpty == false
            && attachmentOwnersByTerminalID[terminalID]?.keys.contains(where: owns) == true
    }

    func attachedTerminalIDs() -> [String] {
        Array(attachmentOwnersByTerminalID.keys)
    }

    mutating func admit(
        _ event: PreparedTerminalEvent,
        connectionID: Int,
        exitedAt: @autoclosure () -> String
    ) -> TerminalEventReduction {
        switch event {
        case .output(let output):
            if case .gap = admitOutput(
                terminalID: output.terminalId,
                sequence: output.sequence,
                data: output.data,
                connectionID: connectionID
            ) {
                return .reconcile(terminalID: output.terminalId)
            }
        case .exit(let exit):
            _ = admitExit(
                terminalID: exit.terminalId,
                sequence: exit.sequence,
                exitCode: exit.exitCode,
                exitedAt: exitedAt(),
                connectionID: connectionID
            )
        }
        return .none
    }

    mutating func admitOutput(
        terminalID: String,
        sequence: Int,
        data: String,
        connectionID: Int
    ) -> TerminalOutputAdmission {
        let hasAttachment = hasAttachedOwner(in: terminalID, connectionID: connectionID)
        let hasPendingAttachment = hasPendingAttachmentOperation(
            in: terminalID,
            connectionID: connectionID
        )
        if hasPendingAttachment {
            bufferOutput(terminalID: terminalID, sequence: sequence, data: data)
            return .buffered
        }
        guard hasAttachment || hasPendingOpen(connectionID: connectionID) else { return .ignored }
        guard hasAttachment else {
            bufferOutput(terminalID: terminalID, sequence: sequence, data: data)
            return .buffered
        }
        let latest = replayByID[terminalID]?.chunks.last?.sequence ?? 0
        guard sequence > latest else { return .ignored }
        guard sequence == latest + 1 else {
            bufferOutput(terminalID: terminalID, sequence: sequence, data: data)
            return .gap(after: latest)
        }
        appendOutput(terminalID: terminalID, sequence: sequence, data: data)
        return .appended
    }

    mutating func admitExit(
        terminalID: String,
        sequence: Int?,
        exitCode: Int?,
        exitedAt: String,
        connectionID: Int
    ) -> Bool {
        let hasAttachment = hasAttachedOwner(in: terminalID, connectionID: connectionID)
        let hasPendingAttachment = hasPendingAttachmentOperation(
            in: terminalID,
            connectionID: connectionID
        )
        guard hasAttachment || hasPendingAttachment || hasPendingOpen(connectionID: connectionID) else {
            return false
        }
        guard hasAttachment, !hasPendingAttachment else {
            var pending = pendingEventsByTerminalID[terminalID] ?? PendingEvents()
            pending.exit = (sequence, exitCode, exitedAt)
            pendingEventsByTerminalID[terminalID] = pending
            trimPendingEvents()
            return true
        }
        applyExit(
            terminalID: terminalID,
            sequence: sequence,
            exitCode: exitCode,
            exitedAt: exitedAt
        )
        return true
    }

    mutating func clear() {
        nextPresentationGeneration &+= 1
        nextIntentGeneration &+= 1
        nextOperationGeneration &+= 1
        presentations.removeAll()
        activeIntentByPresentation.removeAll()
        operationByKey.removeAll()
        openOperationByIntent.removeAll()
        attachmentOwnersByTerminalID.removeAll()
        lastInstalledOperationByTerminalID.removeAll()
        lastProvenSequenceByTerminalID.removeAll()
        pendingEventsByTerminalID.removeAll()
        pendingOverflowGeneration &+= 1
        immediateRecoveryAttemptsByTerminalID.removeAll()
        reconcilingTerminalIDs.removeAll()
        terminalIDsBySession.removeAll()
        replayByID.removeAll()
        exitedTerminalIDs.removeAll()
    }

    private mutating func invalidateWork(
        for target: TerminalPresentationTarget
    ) -> [TerminalDetachClaim] {
        var detached: [TerminalDetachClaim] = []
        var affectedTerminalIDs: Set<String> = []
        for (terminalID, existingOwners) in attachmentOwnersByTerminalID {
            var owners = existingOwners
            let removed = owners.filter { $0.key.presentation == target }
            guard !removed.isEmpty else { continue }
            affectedTerminalIDs.insert(terminalID)
            for intent in removed.keys { owners.removeValue(forKey: intent) }
            owners = owners.filter { owns($0.key) }
            if owners.isEmpty {
                attachmentOwnersByTerminalID.removeValue(forKey: terminalID)
                // Keep the last admitted replay as a bounded UI projection until
                // authoritative inventory or a new owner replaces it. Ownership
                // is already gone, so stale events cannot mutate this projection.
                lastInstalledOperationByTerminalID.removeValue(forKey: terminalID)
                lastProvenSequenceByTerminalID.removeValue(forKey: terminalID)
                exitedTerminalIDs.remove(terminalID)
                pendingEventsByTerminalID.removeValue(forKey: terminalID)
                if let connectionID = removed.values.first {
                    detached.append(TerminalDetachClaim(
                        terminalID: terminalID,
                        connectionID: connectionID
                    ))
                }
            } else {
                attachmentOwnersByTerminalID[terminalID] = owners
            }
        }
        let operationKeys = operationByKey.keys.filter { $0.intent.presentation == target }
        for key in operationKeys {
            affectedTerminalIDs.insert(key.terminalID)
            operationByKey.removeValue(forKey: key)
        }
        for intent in openOperationByIntent.keys where intent.presentation == target {
            openOperationByIntent.removeValue(forKey: intent)
        }
        for terminalID in affectedTerminalIDs where !operationByKey.keys.contains(where: {
            $0.terminalID == terminalID
        }) {
            reconcilingTerminalIDs.remove(terminalID)
        }
        pruneUnownedPendingEvents()
        return detached
    }

    private func hasAttachedOwner(in terminalID: String, connectionID: Int) -> Bool {
        attachmentOwnersByTerminalID[terminalID]?.contains(where: {
            $0.value == connectionID && owns($0.key)
        }) == true
    }

    private func hasPendingAttachmentOperation(
        in terminalID: String,
        connectionID: Int
    ) -> Bool {
        operationByKey.values.contains {
            $0.requestedTerminalID == terminalID
                && $0.connectionID == connectionID
                && owns($0.intent)
        }
    }

    private func hasPendingOpen(connectionID: Int) -> Bool {
        openOperationByIntent.values.contains {
            $0.connectionID == connectionID && owns($0.intent)
        }
    }

    private mutating func pruneUnownedPendingEvents() {
        guard openOperationByIntent.isEmpty else { return }
        pendingEventsByTerminalID = pendingEventsByTerminalID.filter { terminalID, _ in
            attachmentOwnersByTerminalID[terminalID] != nil
                || operationByKey.keys.contains(where: { $0.terminalID == terminalID })
        }
    }

    private mutating func bufferOutput(terminalID: String, sequence: Int, data: String) {
        var pending = pendingEventsByTerminalID[terminalID] ?? PendingEvents()
        guard pending.outputBySequence[sequence] == nil else { return }
        let chunk = TerminalChunk(sequence: sequence, data: data)
        pending.outputBySequence[sequence] = chunk
        pending.outputBytes += data.utf8.count
        pendingEventsByTerminalID[terminalID] = pending
        trimPendingEvents()
    }

    private mutating func trimPendingEvents() {
        while pendingEventsByTerminalID.count > Self.maximumPendingTerminalCount {
            guard let terminalID = pendingEventsByTerminalID.keys.min() else { break }
            pendingEventsByTerminalID.removeValue(forKey: terminalID)
            pendingOverflowGeneration &+= 1
        }
        while pendingEventsByTerminalID.values.reduce(0, { $0 + $1.outputBySequence.count })
                > Self.maximumPendingOutputCount
            || pendingEventsByTerminalID.values.reduce(0, { $0 + $1.outputBytes })
                > Self.maximumPendingOutputBytes {
            let candidate = pendingEventsByTerminalID.compactMap { terminalID, pending -> (String, Int)? in
                pending.outputBySequence.keys.min().map { (terminalID, $0) }
            }.min {
                $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
            }
            guard let (terminalID, sequence) = candidate,
                  var pending = pendingEventsByTerminalID[terminalID],
                  let removed = pending.outputBySequence.removeValue(forKey: sequence) else { break }
            pending.outputBytes -= removed.data.utf8.count
            pending.requiresReconciliation = true
            pendingOverflowGeneration &+= 1
            if pending.outputBySequence.isEmpty, pending.exit == nil {
                pendingEventsByTerminalID.removeValue(forKey: terminalID)
            } else {
                pendingEventsByTerminalID[terminalID] = pending
            }
        }
    }

    private mutating func drainPendingEvents(
        terminalID: String
    ) -> TerminalReplayInstallation {
        guard var pending = pendingEventsByTerminalID.removeValue(forKey: terminalID) else {
            return TerminalReplayInstallation(admittedCount: 0, requiresReconciliation: false)
        }
        var admittedCount = 0
        var requiresReconciliation = pending.requiresReconciliation
        pending.requiresReconciliation = false
        for sequence in pending.outputBySequence.keys.sorted() {
            guard let chunk = pending.outputBySequence[sequence] else { continue }
            let latest = lastProvenSequenceByTerminalID[terminalID]
                ?? replayByID[terminalID]?.chunks.last?.sequence
                ?? 0
            if sequence <= latest {
                pending.outputBytes -= chunk.data.utf8.count
                pending.outputBySequence.removeValue(forKey: sequence)
            } else if sequence == latest + 1 {
                appendOutput(terminalID: terminalID, sequence: sequence, data: chunk.data)
                admittedCount += 1
                pending.outputBytes -= chunk.data.utf8.count
                pending.outputBySequence.removeValue(forKey: sequence)
            } else {
                requiresReconciliation = true
            }
        }
        if let exit = pending.exit {
            applyExit(
                terminalID: terminalID,
                sequence: exit.sequence,
                exitCode: exit.code,
                exitedAt: exit.date
            )
            pending.exit = nil
        }
        if !pending.outputBySequence.isEmpty {
            pendingEventsByTerminalID[terminalID] = pending
        }
        return TerminalReplayInstallation(
            admittedCount: admittedCount,
            requiresReconciliation: requiresReconciliation
        )
    }

    private mutating func appendOutput(terminalID: String, sequence: Int, data: String) {
        let current = replayByID[terminalID] ?? .empty
        replayByID[terminalID] = TerminalReplayProjection(
            chunks: Self.boundedReplay(
                current.chunks + [TerminalChunk(sequence: sequence, data: data)]
            ),
            revision: current.revision
        )
        updateSequence(terminalID, sequence: sequence)
    }

    private static func boundedReplay(_ chunks: [TerminalChunk]) -> [TerminalChunk] {
        var firstRetainedIndex = chunks.count
        var retainedCount = 0
        var retainedBytes = 0
        for index in chunks.indices.reversed() {
            let bytes = chunks[index].data.utf8.count
            guard retainedCount < maximumReplayOutputCount,
                  bytes <= maximumReplayOutputBytes - retainedBytes else { break }
            firstRetainedIndex = index
            retainedCount += 1
            retainedBytes += bytes
        }
        return firstRetainedIndex == chunks.count ? [] : Array(chunks[firstRetainedIndex...])
    }

    private mutating func applyExit(
        terminalID: String,
        sequence: Int?,
        exitCode: Int?,
        exitedAt: String
    ) {
        exitedTerminalIDs.insert(terminalID)
        // Exit state is a bounded terminal projection; the canonical summary
        // remains owned by the authoritative inventory.
        _ = sequence
        _ = exitedAt
        _ = exitCode
    }

    private mutating func updateSequence(_ terminalID: String, sequence: Int) {
        lastProvenSequenceByTerminalID[terminalID] = max(
            lastProvenSequenceByTerminalID[terminalID] ?? 0,
            sequence
        )
    }
}
