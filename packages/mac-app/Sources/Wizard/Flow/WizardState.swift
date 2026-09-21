import Foundation
import Observation

/// Resume progress + transient state for the wizard. Progress is owned by the
/// Mac wrapper at `internal/mac/wizard-state.json`; completion remains owned
/// exclusively by the on-disk `.onboarded` sentinel.
@MainActor
@Observable
final class WizardState {
    static let stateFileVersion = 1
    static let defaultStateURL = TronPaths.internalDir
        .appendingPathComponent("mac", isDirectory: true)
        .appendingPathComponent("wizard-state.json", isDirectory: false)

    private let stateURL: URL
    private(set) var persistenceFailure: String? = nil

    var step: WizardStep {
        didSet {
            do {
                try Self.write(step: step, to: stateURL)
                persistenceFailure = nil
            } catch {
                // The new value remains visible, but the error is explicit. The
                // wrapper never silently resets progress or mirrors it in prefs.
                persistenceFailure = error.localizedDescription
            }
        }
    }

    /// Direction of the most recent navigation, set BEFORE `step` is
    /// mutated by every navigation method (`advance`, `goBack`, and
    /// `skipToPairing`). `WizardShell.slideTransition` reads this single source
    /// of truth to pick the asymmetric move-edge pair.
    var slideDirection: WizardSlideDirection = .forward

    var tailscaleStatus: TailscaleStatus?
    var permissionStatuses: [Permission: PermissionStatus] = [:]
    var permissionsServerRestarted = false
    var permissionsRestartInProgress = false
    var existingInstallStatus: ExistingInstallStatus = .none
    var installOutcome: InstallOutcome?
    private var installTask: Task<Void, Never>?
    var installStages: [InstallPipelineStage: InstallStageState] = [:]
    var installIsRunning: Bool { installTask != nil }
    var needsInstallDetection: Bool { !installIsRunning && installOutcome == nil }

    func refreshExistingInstall(using probe: @Sendable () async -> ExistingInstallStatus) async {
        guard needsInstallDetection else { return }
        let status = await probe()
        guard !Task.isCancelled, needsInstallDetection else { return }
        existingInstallStatus = status
    }

    var pairingPayload: PairingPayload?

    init(stateURL: URL = WizardState.defaultStateURL, initialStep: WizardStep? = nil) {
        self.stateURL = stateURL
        let persisted = Self.readRecord(from: stateURL)
        let persistedStep: WizardStep?
        if case let .valid(step) = persisted {
            persistedStep = step
        } else {
            persistedStep = nil
        }
        let selected: WizardStep
        if let initialStep {
            selected = initialStep
        } else if let persistedStep, Self.isSafeToResume(persistedStep) {
            selected = persistedStep
        } else {
            selected = .welcome
        }
        self.step = selected
        // An unknown/newer record is owned by a future wrapper and must remain
        // intact. Only a deliberate initial-step override or a known record
        // that needs the cold-start clamp may replace it.
        let shouldWrite: Bool
        switch persisted {
        case .absent:
            // An absent record is deliberate during cutover: the operator may
            // still need to stage the retired UserDefaults key. Do not create
            // a Welcome record on startup and thereby erase resumable legacy
            // progress before that manual migration runs. Explicit recovery
            // overrides and navigation persist through the normal writer.
            shouldWrite = initialStep != nil
        case .valid(let step):
            shouldWrite = initialStep != nil || selected != step
        case .invalid:
            shouldWrite = initialStep != nil
        }
        if shouldWrite {
            do {
                try Self.write(step: selected, to: stateURL)
            } catch {
                self.persistenceFailure = error.localizedDescription
            }
        }
    }

    private enum PersistedRecord {
        case absent
        case valid(WizardStep)
        case invalid
    }

    private static func readRecord(from url: URL) -> PersistedRecord {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == stateFileVersion,
              let raw = object["step"] as? String,
              let step = WizardStep(rawValue: raw) else { return .invalid }
        return .valid(step)
    }

    private static func write(step: WizardStep, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let object: [String: Any] = ["version": stateFileVersion, "step": step.rawValue]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let temporary = parent.appendingPathComponent(".wizard-state.\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func isSafeToResume(_ step: WizardStep) -> Bool {
        switch step {
        case .welcome, .tailscale, .install, .iosBeta: return true
        case .permissions, .pairingInfo, .done: return false
        }
    }

    func advance() {
        let candidates = WizardStep.allCases
        guard let currentIndex = candidates.firstIndex(of: step), currentIndex + 1 < candidates.count else { return }
        navigate(to: candidates[currentIndex + 1], direction: .forward)
    }

    func goBack() {
        let candidates = WizardStep.allCases
        guard let currentIndex = candidates.firstIndex(of: step), currentIndex > 0 else { return }
        navigate(to: candidates[currentIndex - 1], direction: .backward)
    }

    func skipToPairing() { navigate(to: .pairingInfo, direction: .forward) }

    @discardableResult
    func requestInstall(using setup: EnvironmentSetup) -> Task<Void, Never> {
        if let installTask { return installTask }
        installOutcome = nil
        installStages = Dictionary(uniqueKeysWithValues: InstallPipelineStage.allCases.map { ($0, .pending) })
        installStages[.validateApplication] = .running
        let task = Task {
            defer { installTask = nil }
            await performInstall(setup: setup)
        }
        installTask = task
        return task
    }

    private func navigate(to next: WizardStep, direction: WizardSlideDirection) {
        slideDirection = direction
        step = next
    }
}

enum WizardSlideDirection: Sendable, Equatable {
    case forward
    case backward
}

enum InstallOutcome: Equatable, Sendable {
    case success
    case invalidApplicationLocation(String)
    case helperValidationFailed(String)
    case serviceRequiresApproval
    case serviceRegistrationFailed(String)
    case awaitPingTimedOut
}
