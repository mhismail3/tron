import AppKit
import Darwin
import Foundation
import TronComputerControl

enum ObserverQualificationScope: String, Codable, Sendable { case session, selfProcess }

struct ObserverQualificationConfig: Equatable, Sendable {
    let deadlineMilliseconds: UInt64
    let scope: ObserverQualificationScope
    init(deadlineMilliseconds: UInt64, scope: ObserverQualificationScope = .session) {
        self.deadlineMilliseconds = deadlineMilliseconds; self.scope = scope
    }
    static let defaults = Self(deadlineMilliseconds: 5_000)
}

enum ObserverQualificationInvocation: Equatable {
    case help
    case observe(ObserverQualificationConfig)
    case invalid(String)

    static func parse(_ arguments: [String]) -> Self {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] { return .help }
        let scope: ObserverQualificationScope
        switch arguments.first {
        case "--observe": scope = .session
        case "--observe-self-process": scope = .selfProcess
        default: return .invalid("Use --observe or --observe-self-process [--deadline-ms 1...300000].")
        }
        if arguments.count == 1 { return .observe(.init(deadlineMilliseconds: 5_000, scope: scope)) }
        guard arguments.count == 3, arguments[1] == "--deadline-ms",
              let value = UInt64(arguments[2]), (1...300_000).contains(value) else {
            return .invalid("Use --observe or --observe-self-process [--deadline-ms 1...300000].")
        }
        return .observe(.init(deadlineMilliseconds: value, scope: scope))
    }
}

struct ObserverQualificationAvailability: Codable, Equatable, Sendable {
    let available: Bool
    let generationID: String?
    let generationNumber: UInt64?
    let reason: String?
}

struct ObserverQualificationReport: Codable, Equatable, Sendable {
    let schema: String
    let processIdentifier: Int32
    let scope: ObserverQualificationScope
    let deadlineMilliseconds: UInt64
    let requestedEventsOfInterest: UInt64
    let inventoryBefore: [NativeEventTapInventoryEntry]
    let availability: ObserverQualificationAvailability
    let inventoryAfterStart: [NativeEventTapInventoryEntry]
    let inventoryAfterStop: [NativeEventTapInventoryEntry]
    let newlyOwnedTapIDs: [UInt32]
    let stopJoined: Bool
    let deadlineTriggered: Bool
    let cancellationObserved: Bool
    let callbackActivityCount: UInt64
    let inventoryError: String?

    var passed: Bool {
        availability.available && !deadlineTriggered && !cancellationObserved && validationErrors().isEmpty
    }

    /// Evidence validation is separate from success: a well-formed permission
    /// refusal is still an unsuccessful qualification, never an empty-set pass.
    func validationErrors() -> [String] {
        var errors: [String] = []
        if schema != "tron.native-observer-qualification.v2" { errors.append("schema mismatch") }
        if processIdentifier <= 0 || !(1...300_000).contains(deadlineMilliseconds) { errors.append("invalid configuration") }
        if requestedEventsOfInterest != NativeEventObserver.requiredEventsOfInterest { errors.append("noncanonical requested mask") }
        if inventoryError != nil { errors.append("tap inventory is incomplete") }
        if !stopJoined { errors.append("observer stop was not joined") }
        if callbackActivityCount > 1 { errors.append("activity indication exceeded bound") }
        for inventory in [inventoryBefore, inventoryAfterStart, inventoryAfterStop] {
            if inventory.count > 64 { errors.append("tap inventory exceeded bound") }
            if Set(inventory.map(\.eventTapID)).count != inventory.count { errors.append("duplicate tap IDs") }
            if !inventory.allSatisfy({ $0.tappingProcess == processIdentifier }) { errors.append("foreign process in inventory") }
        }
        let before = Set(inventoryBefore.map(\.eventTapID))
        let after = Set(inventoryAfterStart.map(\.eventTapID))
        let owned = Set(newlyOwnedTapIDs)
        if owned.count != newlyOwnedTapIDs.count || owned != after.subtracting(before) {
            errors.append("newly-owned tap set mismatch")
        }
        if !before.isSubset(of: after) { errors.append("baseline tap disappeared during startup") }
        if inventoryBefore.sorted(by: { $0.eventTapID < $1.eventTapID }) != inventoryAfterStop.sorted(by: { $0.eventTapID < $1.eventTapID }) {
            errors.append("post-join inventory did not return to baseline")
        }
        if availability.available {
            if availability.generationID.flatMap(UUID.init(uuidString:)) == nil || availability.generationNumber != 1 || availability.reason != nil {
                errors.append("invalid available generation")
            }
            if newlyOwnedTapIDs.count != 1 { errors.append("available observer must own exactly one new tap") }
            for entry in inventoryAfterStart where owned.contains(entry.eventTapID) {
                if entry.processBeingTapped != (scope == .session ? 0 : processIdentifier)
                    || (scope == .session && entry.tapPointRawValue != Int32(CGEventTapLocation.cgSessionEventTap.rawValue))
                    || entry.optionsRawValue != UInt32(CGEventTapOptions.listenOnly.rawValue)
                    || entry.eventsOfInterest != requestedEventsOfInterest || !entry.enabled {
                    errors.append("owned tap metadata does not match requested session observer")
                }
            }
        } else {
            if availability.reason?.isEmpty != false || availability.generationID != nil || availability.generationNumber != nil {
                errors.append("invalid refusal metadata")
            }
            if !newlyOwnedTapIDs.isEmpty { errors.append("unavailable startup retained a tap") }
        }
        return errors
    }
}

private final class QualificationState: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: UInt64 = 0
    private var deadline = false
    private var cancelled = false
    func sawActivity() { lock.withLock { activity = 1 } }
    func markDeadline() { lock.withLock { deadline = true } }
    func markCancelled() { lock.withLock { cancelled = true } }
    var snapshot: (activity: UInt64, deadline: Bool, cancelled: Bool) {
        lock.withLock { (activity, deadline, cancelled) }
    }
}

enum ObserverQualificationLifecycle {
    static func run(_ config: ObserverQualificationConfig) async -> ObserverQualificationReport {
        let state = QualificationState()
        let target: NativeEventTapTarget = config.scope == .session ? .session : .process(getpid())
        let observer = NativeEventObserver(target: target, activity: { state.sawActivity() })
        return await withTaskCancellationHandler {
            await execute(config, observer: observer, state: state)
        } onCancel: {
            state.markCancelled()
            observer.requestStop()
        }
    }

    private static func execute(_ config: ObserverQualificationConfig, observer: NativeEventObserver,
                                state: QualificationState) async -> ObserverQualificationReport {
        let deadline = Task.detached {
            do { try await Task.sleep(for: .milliseconds(config.deadlineMilliseconds)) } catch { return }
            state.markDeadline()
            observer.requestStop()
        }
        let before = inventory()
        let availability = await observer.start()
        let started = inventory()
        observer.requestStop()
        await observer.stopAndJoin()
        deadline.cancel()
        await deadline.value // Freeze deadline metadata only after its actual completion.
        let stopped = inventory()
        let beforeIDs = Set(before.entries.map(\.eventTapID))
        let owned = started.entries.map(\.eventTapID).filter { !beforeIDs.contains($0) }.sorted()
        let errors = [before.error, started.error, stopped.error].compactMap { $0 }
        let available: ObserverQualificationAvailability
        switch availability {
        case let .available(generation):
            available = .init(available: true, generationID: generation.id.uuidString,
                              generationNumber: generation.number, reason: nil)
        case let .unavailable(reason):
            available = .init(available: false, generationID: nil, generationNumber: nil, reason: reason)
        }
        let final = state.snapshot
        return .init(schema: "tron.native-observer-qualification.v2", processIdentifier: getpid(), scope: config.scope,
                     deadlineMilliseconds: config.deadlineMilliseconds,
                     requestedEventsOfInterest: NativeEventObserver.requiredEventsOfInterest,
                     inventoryBefore: before.entries, availability: available,
                     inventoryAfterStart: started.entries, inventoryAfterStop: stopped.entries,
                     newlyOwnedTapIDs: owned, stopJoined: true,
                     deadlineTriggered: final.deadline, cancellationObserved: final.cancelled,
                     callbackActivityCount: final.activity,
                     inventoryError: errors.isEmpty ? nil : errors.joined(separator: "; "))
    }

    private static func inventory() -> (entries: [NativeEventTapInventoryEntry], error: String?) {
        do { return (try NativeEventTapInventory.currentProcess(), nil) }
        catch { return ([], String(describing: error)) }
    }
}

@main
@MainActor
struct TronNativeObserverQualification {
    static func main() {
        switch ObserverQualificationInvocation.parse(Array(CommandLine.arguments.dropFirst())) {
        case .help:
            print("Usage: TronNativeObserverQualification --observe|--observe-self-process [--deadline-ms N]")
            print("Creates one listen-only observer, then joins Stop. Process mode targets only this process. No input is posted.")
        case let .invalid(reason):
            FileHandle.standardError.write(Data("Qualification refused: \(reason)\n".utf8))
            exit(2)
        case let .observe(config):
            // Native construction is reachable only after explicit, valid opt-in.
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let operation = Task { @MainActor in
                let report = await ObserverQualificationLifecycle.run(config)
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(report) + Data("\n".utf8))
                    exit(report.passed ? 0 : 1) // No unavailable/deadline/cancelled success.
                } catch {
                    FileHandle.standardError.write(Data("Qualification report failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { operation.cancel() }
                source.resume()
                return source
            }
            withExtendedLifetime(signals) { application.run() }
        }
    }
}
