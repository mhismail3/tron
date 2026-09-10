import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PeekabooAutomationKit

private enum BackgroundQualificationMode: Equatable {
    case combined
    case axOnly

    var argument: String {
        switch self {
        case .combined: "--background-qualification"
        case .axOnly: "--background-ax-only"
        }
    }

    var captures: Bool { self == .combined }
}

private enum QualificationError: LocalizedError {
    case invalidInvocation
    case timeout(String)
    case identity(String)
    case accessibility(String)
    case accessibilityNotReady(String)
    case capture(String)
    case effect(String)

    var code: String {
        switch self {
        case .invalidInvocation: "invalid_invocation"
        case .timeout: "timeout"
        case .identity: "identity_mismatch"
        case .accessibility: "accessibility_refused"
        case .accessibilityNotReady: "accessibility_not_ready"
        case .capture: "capture_refused"
        case .effect: "effect_unverified"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidInvocation: "Only --preflight, --capture-owner-check, --fixture --nonce <UUID>, --background-qualification, --background-ax-only, or --capture-coexistence is supported."
        case let .timeout(message), let .identity(message), let .accessibility(message),
             let .accessibilityNotReady(message), let .capture(message), let .effect(message): message
        }
    }
}

private struct QualificationReport: Encodable {
    let schema = "tron.computer-use.native-qualification.v2"
    let hostGeneration: UUID
    let mode: String
    let bundleIdentifier: String?
    let executablePath: String
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let accessibilityTrusted: Bool
    let screenCapturePreflight: Bool
    let guiSessionLocked: Bool?
    let capabilities: [String]
    let nativeActions: String
    let capture: String
    let fixture: FixtureReceipt?
    let screenshots: ScreenshotReceipt?
    let foregroundSentinelBefore: FrontmostReceipt?
    let foregroundSentinelAfter: FrontmostReceipt?
    let backgroundNonActivationVerified: Bool
    let windowOrderBefore: [CGWindowID]?
    let windowOrderAfter: [CGWindowID]?
}

private struct FixtureReceipt: Encodable {
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let windowID: CGWindowID
    let nonce: String
    let title: String
    let bounds: CGRect
    let effectBefore: Int
    let effectAfter: Int
    let nativeActionEvidence: String
    let actionReceiptIdentity: ActionReceiptIdentity
    let retired: Bool
}

private struct ActionReceiptIdentity: Encodable {
    let windowID: Int
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let bounds: CGRect
}

private struct ScreenshotReceipt: Encodable {
    let beforePath: String
    let afterPath: String
    let beforeBytes: Int
    let afterBytes: Int
    let beforePixelSize: CGSize
    let afterPixelSize: CGSize
    let beforeGreenMarkerSamples: Int
    let beforeRedMarkerSamples: Int
    let afterGreenMarkerSamples: Int
    let afterRedMarkerSamples: Int
    let captureEngine: String
}

private struct FrontmostReceipt: Encodable, Equatable {
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let bundleIdentifier: String?
}

private struct FixtureReady: Codable {
    let pid: Int32
    let nonce: String
    let bundleIdentifier: String?
    let executablePath: String
}

private struct MarkerEvidence {
    let green: Int
    let red: Int
}

@MainActor
private final class QualificationFailureState {
    let hostGeneration: UUID
    let executablePath: String
    let deadline: QualificationDeadline
    var child: Process? { didSet { publishDeadline() } }
    var childRetired: Bool? { didSet { publishDeadline() } }
    var target: WindowMutationIdentity? { didSet { publishDeadline() } }
    var effectState = "not-started" { didSet { publishDeadline() } }
    var nativeQuiescence = "not-started" { didSet { publishDeadline() } }

    init() throws {
        let generation = UUID()
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        hostGeneration = generation
        executablePath = path
        let initial = FailureReceipt(
            hostGeneration: generation, executablePath: path,
            controllerProcessIdentifier: getpid(), errorCode: "native_deadline",
            error: "Qualification deadline; this controller exits without claiming native Stop or rollback.",
            effectState: "not-started", nativeQuiescence: "uncertain-controller-exiting",
            fixtureProcessIdentifier: nil, fixtureWindowID: nil,
            fixtureProcessStartIdentity: nil, fixtureRetired: nil)
        deadline = QualificationDeadline(report: try JSONEncoder().encode(initial))
    }

    func failure(error: any Error) -> FailureReceipt {
        FailureReceipt(
            hostGeneration: hostGeneration, executablePath: executablePath,
            controllerProcessIdentifier: getpid(),
            errorCode: (error as? QualificationError)?.code ?? "native-qualification-failed",
            error: String(error.localizedDescription.prefix(2_048)), effectState: effectState,
            nativeQuiescence: nativeQuiescence == "in-flight" ? "uncertain-not-joined" : nativeQuiescence,
            fixtureProcessIdentifier: child?.processIdentifier,
            fixtureWindowID: target.map { CGWindowID($0.windowID) },
            fixtureProcessStartIdentity: target?.ownerProcessStartIdentity,
            fixtureRetired: childRetired)
    }

    private func publishDeadline() {
        let receipt = FailureReceipt(
            hostGeneration: hostGeneration, executablePath: executablePath,
            controllerProcessIdentifier: getpid(), errorCode: "native_deadline",
            error: "Qualification deadline; process containment, not native Stop. Parent must verify both exact processes retired.",
            effectState: effectState, nativeQuiescence: "uncertain-controller-exiting",
            fixtureProcessIdentifier: child?.processIdentifier,
            fixtureWindowID: target.map { CGWindowID($0.windowID) },
            fixtureProcessStartIdentity: target?.ownerProcessStartIdentity,
            fixtureRetired: childRetired)
        if let data = try? JSONEncoder().encode(receipt) { deadline.update(data) }
    }
}

private struct FailureReceipt: Encodable {
    let schema = "tron.computer-use.native-qualification-failure.v1"
    let hostGeneration: UUID
    let executablePath: String
    let controllerProcessIdentifier: Int32
    let errorCode: String
    let error: String
    let effectState: String
    let nativeQuiescence: String
    let fixtureProcessIdentifier: Int32?
    let fixtureWindowID: CGWindowID?
    let fixtureProcessStartIdentity: UInt64?
    let fixtureRetired: Bool?
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didOverflow = false
    private let limit = 8 * 1024

    func start(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    func stop(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func append(_ chunk: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.didOverflow else { return }
        guard self.data.count + chunk.count <= self.limit else {
            self.didOverflow = true
            return
        }
        self.data.append(chunk)
    }

    var readiness: FixtureReady? {
        self.lock.lock()
        let snapshot = self.data
        let overflow = self.didOverflow
        self.lock.unlock()
        guard !overflow,
              let line = snapshot.split(separator: 10).first,
              !line.isEmpty
        else { return nil }
        return try? JSONDecoder().decode(FixtureReady.self, from: Data(line))
    }

    var overflowed: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.didOverflow
    }
}

@MainActor
private final class FixtureMarkerView: NSView {
    var isIncremented = false

    override func draw(_ dirtyRect: NSRect) {
        let color = isIncremented
            ? NSColor(calibratedRed: 0.88, green: 0.08, blue: 0.08, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.12, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class QualificationFixture: NSObject, NSApplicationDelegate {
    let nonce: String
    private let window: NSWindow
    private let countLabel: NSTextField
    private let markerView: FixtureMarkerView
    private var count = 0

    init(nonce: String) {
        self.nonce = nonce
        self.window = NSWindow(
            contentRect: NSRect(x: 240, y: 220, width: 520, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        self.countLabel = NSTextField(labelWithString: "count:0")
        self.markerView = FixtureMarkerView()
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Tron native qualification fixture")
        title.alignment = .center
        title.frame = NSRect(x: 30, y: 170, width: 460, height: 28)
        title.autoresizingMask = [.width, .minYMargin]
        content.addSubview(title)

        markerView.frame = NSRect(x: 30, y: 145, width: 460, height: 38)
        markerView.autoresizingMask = [.width, .minYMargin]
        content.addSubview(markerView)

        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 30, y: 100, width: 460, height: 32)
        countLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(countLabel)

        let button = NSButton(
            title: "Increment \(nonce)",
            target: self,
            action: #selector(increment(_:)))
        button.setAccessibilityIdentifier("tron.qualification.increment.\(nonce)")
        button.frame = NSRect(x: 140, y: 42, width: 240, height: 38)
        button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(button)

        window.title = "Tron Qualification Fixture \(nonce)"
        window.animationBehavior = .none
        window.contentView = content
        window.isReleasedWhenClosed = false
        // Setup maps only this new fixture behind existing windows. Background
        // qualification independently verifies the complete normal-window order.
        window.orderBack(nil)
        window.displayIfNeeded()
        writeReady()
    }

    @objc private func increment(_: Any?) {
        count += 1
        countLabel.stringValue = "count:\(count)"
        markerView.isIncremented = true
        markerView.needsDisplay = true
        markerView.displayIfNeeded()
    }

    private func writeReady() {
        let ready = FixtureReady(
            pid: getpid(), nonce: nonce,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        if let data = try? JSONEncoder().encode(ready) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

@main
@MainActor
struct TronComputerUseQualification {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--preflight"] {
                try preflight()
            } else if arguments == ["--capture-owner-check"] {
                try captureOwnerCheck()
            } else if arguments.count == 3, arguments[0] == "--fixture", arguments[1] == "--nonce",
                      UUID(uuidString: arguments[2]) != nil
            {
                runFixture(nonce: arguments[2])
            } else if arguments == ["--background-qualification"] {
                runController { try await runBackgroundQualification(mode: .combined) }
            } else if arguments == ["--background-ax-only"] {
                runController { try await runBackgroundQualification(mode: .axOnly) }
            } else if arguments == ["--capture-coexistence"] {
                runController { try await runCaptureCoexistence() }
            } else {
                throw QualificationError.invalidInvocation
            }
        } catch { exitWithFailure(error) }
    }

    private static func runController(_ operation: @escaping @MainActor () async throws -> Void) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await operation()
                _exit(0)
            } catch { exitWithFailure(error) }
        }
        // AppKit owns the top-level run loop. A nested run() inside async main's
        // MainActor job can starve AX/main-queue IPC despite a visible window.
        application.run()
    }

    private static func exitWithFailure(_ error: any Error) -> Never {
        FileHandle.standardError.write(Data("Qualification refused: \(error.localizedDescription)\n".utf8))
        // Only this one-shot controller exits. Its fixture receives EOF; no PID
        // signal fallback and no native thread survives controller retirement.
        _exit(1)
    }

    private static func preflight() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        // These are consent preflights, not permission requests. No window
        // enumeration, screen capture, AX action, or physical input occurs here.
        let report = QualificationReport(
            hostGeneration: UUID(),
            mode: "preflight",
            bundleIdentifier: Bundle.main.bundleIdentifier,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            processIdentifier: getpid(),
            parentProcessIdentifier: getppid(),
            accessibilityTrusted: AXIsProcessTrusted(),
            screenCapturePreflight: CGPreflightScreenCaptureAccess(),
            guiSessionLocked: guiSessionLocked(),
            capabilities: [
                "non-prompting-permission-preflight",
                "background-ax-exact-window-capture",
                "owned-app-effect-oracle",
            ],
            nativeActions: "available-but-not-attempted",
            capture: "not-attempted",
            fixture: nil,
            screenshots: nil,
            foregroundSentinelBefore: nil,
            foregroundSentinelAfter: nil,
            backgroundNonActivationVerified: false,
            windowOrderBefore: nil, windowOrderAfter: nil)
        try write(report)
    }

    private static func guiSessionLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func requireUnlockedGUI() throws {
        guard guiSessionLocked() == false else {
            throw QualificationError.identity("macOS GUI session is locked or unavailable; user unlock is required. No native action is admitted.")
        }
    }

    private static func captureOwnerCheck() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        struct OwnerCheck: Encodable {
            let schema = "tron.computer-use.capture-owner-check.v1"
            let capture = "not-attempted"
            let owner: ScreenCaptureKitOwnerLease.OwnerReceipt
            let guiSessionLocked: Bool?
        }
        let state = try QualificationFailureState()
        do {
            let owner = try ScreenCaptureKitOwnerLease().claim().receipt
            let report = OwnerCheck(owner: owner, guiSessionLocked: guiSessionLocked())
            guard state.deadline.disarm() else { _exit(124) }
            FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
        } catch {
            if state.deadline.disarm() { try? writeFailure(state.failure(error: error)) }
            throw error
        }
    }

    private static func runFixture(nonce: String) {
        // A private stdin pipe is the parent-lifetime authority. This does not
        // depend on AppKit/MainActor making progress and cannot signal a reused PID.
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(STDIN_FILENO, &byte, 1)
                if count == 0 || (count < 0 && errno != EINTR) { _exit(0) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _exit(124) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = QualificationFixture(nonce: nonce)
        application.delegate = delegate
        // NSApplication and NSControl targets do not own this local controller.
        // Its window/action handler must survive the entire fixture run loop.
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runBackgroundQualification(mode: BackgroundQualificationMode) async throws {
        let state = try QualificationFailureState()
        do {
            try await runBackgroundQualificationAttempt(state: state, mode: mode)
        } catch {
            if state.deadline.disarm() { try? writeFailure(state.failure(error: error)) }
            throw error
        }
    }

    private static func runBackgroundQualificationAttempt(
        state: QualificationFailureState,
        mode: BackgroundQualificationMode
    ) async throws {
        try requireUnlockedGUI()
        guard AXIsProcessTrusted() else {
            throw QualificationError.accessibility("Accessibility permission is not granted to this exact signed qualification app.")
        }
        if mode.captures, !CGPreflightScreenCaptureAccess() {
            throw QualificationError.capture("Screen Recording permission is not granted to this exact signed qualification app.")
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        guard let sentinelBefore = frontmostReceipt() else {
            throw QualificationError.identity("No independent frontmost-process sentinel was available before fixture launch.")
        }
        let windowOrderBefore = normalWindowOrder()
        guard !windowOrderBefore.isEmpty else {
            throw QualificationError.identity("No visible normal-window sentinel was available before fixture launch.")
        }
        let nonce = UUID().uuidString
        let title = "Tron Qualification Fixture \(nonce)"
        let fixtureURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let child = Process()
        state.child = child
        child.executableURL = fixtureURL
        child.arguments = ["--fixture", "--nonce", nonce]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutDrain = BoundedPipeCollector()
        let stderrDrain = BoundedPipeCollector()
        stdoutDrain.start(stdoutPipe)
        stderrDrain.start(stderrPipe)
        // Only fd 0 is inherited through Process's explicit stdio mapping.
        for descriptor in [stdinPipe.fileHandleForReading.fileDescriptor, stdinPipe.fileHandleForWriting.fileDescriptor] {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw QualificationError.identity("Could not fence the fixture lifetime pipe across exec.")
            }
        }
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        let termination = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in termination.signal() }
        var childRetired = false
        defer {
            childRetired = retireOwnedFixture(child, termination: termination, stdin: stdinPipe)
            state.childRetired = childRetired
            stdoutDrain.stop(stdoutPipe)
            stderrDrain.stop(stderrPipe)
        }
        try child.run()
        state.child = child // publish the real post-spawn PID for timeout evidence

        let startDeadline = ContinuousClock.now + .seconds(10)
        let processStartIdentity: UInt64
        let window: WindowReceipt
        var readiness: FixtureReady?
        while true {
            try Task.checkCancellation()
            if let candidate = stdoutDrain.readiness {
                guard candidate.pid == child.processIdentifier,
                      candidate.nonce == nonce,
                      candidate.bundleIdentifier == Bundle.main.bundleIdentifier,
                      candidate.executablePath == fixtureURL.path
                else { throw QualificationError.identity("Fixture readiness did not bind to the exact signed executable, bundle, PID, and nonce.") }
                readiness = candidate
            }
            guard !stdoutDrain.overflowed, !stderrDrain.overflowed else {
                throw QualificationError.timeout("Fixture diagnostic output exceeded the bounded pipe capacity.")
            }
            guard let identity = SystemIdentityResolver.processStartIdentity(child.processIdentifier) else {
                if ContinuousClock.now >= startDeadline { throw QualificationError.timeout("Fixture process identity was not observable before the deadline.") }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            if let found = exactWindow(pid: child.processIdentifier, title: title), readiness != nil {
                processStartIdentity = identity
                window = found
                break
            }
            if ContinuousClock.now >= startDeadline {
                throw QualificationError.timeout("Owned fixture window was not observable before the deadline.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard processStartIdentity == SystemIdentityResolver.processStartIdentity(child.processIdentifier) else {
            throw QualificationError.identity("Fixture process generation changed before qualification.")
        }
        let identity = WindowMutationIdentity(
            windowID: Int(window.id),
            ownerProcessIdentifier: child.processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: window.bounds,
            isMinimized: false)
        state.target = identity
        let context = WindowContext(
            applicationName: "Tron Computer Use Qualification",
            applicationBundleId: Bundle.main.bundleIdentifier,
            applicationBundlePath: Bundle.main.bundlePath,
            applicationExecutablePath: fixtureURL.path,
            applicationProcessId: child.processIdentifier,
            applicationProcessStartIdentity: processStartIdentity,
            windowTitle: title,
            windowID: Int(window.id),
            windowBounds: window.bounds,
            windowMutationIdentity: identity,
            shouldFocusWebContent: false,
            includeMenuBarElements: false,
            traversalBudget: nil,
            requiresFreshAccessibilityTree: true,
            accessibilityTimeoutSeconds: 5,
            allowApplicationScopedAccessibilityFallback: false)
        let actionOnly = UIInputPolicy(
            defaultStrategy: .actionOnly,
            click: .actionOnly,
            scroll: .actionOnly,
            type: .actionOnly,
            hotkey: .actionOnly,
            setValue: .actionOnly,
            performAction: .actionOnly)
        try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)
        let snapshotManager = InMemorySnapshotManager()
        let automation = UIAutomationService(
            snapshotManager: snapshotManager, inputPolicy: actionOnly)
        state.nativeQuiescence = "in-flight"
        let initial = try await inspectFixtureWhenReady(
            automation, snapshots: snapshotManager, context: context, nonce: nonce, identity: identity,
            deadline: .now + .seconds(5), sentinel: sentinelBefore, windowOrder: windowOrderBefore,
            requireScreenCapture: mode.captures)
        state.nativeQuiescence = "unverified-call-returned"
        let beforeCount = initial.count
        guard beforeCount == 0 else { throw QualificationError.effect("Fixture did not start at count:0.") }
        state.effectState = "before-observed"

        // Combined mode keeps its modern exact-window capture guard. AX-only is
        // deliberately selected at invocation and never reaches ScreenCaptureKit.
        var beforeCapture: CaptureResult?
        var beforeMarker: MarkerEvidence?
        var afterCapture: CaptureResult?
        var afterMarker: MarkerEvidence?
        var outputDirectory: URL?
        let captureService = mode.captures
            ? ScreenCaptureService(loggingService: LoggingService(subsystem: "tron.qualification"))
            : nil
        if mode.captures {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tron-computer-use-qualification-\(nonce)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            outputDirectory = directory

            // Each service call uses Peekaboo's real native operation owner. The exact
            // process/window receipt is revalidated around the calls; no shadow actor
            // or global event path is introduced here.
            try validateFixture(identity, title: title, bounds: window.bounds, requireScreenCapture: true)
            try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)
            state.nativeQuiescence = "in-flight"
            let before = try await captureService!.withCaptureEngine(.modern) {
                try await captureService!.captureWindow(
                    windowID: window.id, visualizerMode: .none, scale: .native)
            }
            state.nativeQuiescence = "unverified-call-returned"
            try validateFixture(identity, title: title, bounds: window.bounds, requireScreenCapture: true)
            beforeCapture = before
            beforeMarker = try validateCapture(before, identity: identity, title: title, bounds: window.bounds)
            try validateFixture(identity, title: title, bounds: window.bounds, requireScreenCapture: true)
            try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)
            state.nativeQuiescence = "in-flight"
        }
        state.nativeQuiescence = "in-flight"
        let action: UIAutomationActionResult<ElementActionResult>
        do {
            action = try await automation.performActionWithOutcome(
                target: initial.button.id,
                actionName: kAXPressAction as String,
                snapshotId: initial.snapshotId)
        } catch {
            // DetachedAXActionRunner can report an operationStillRunning outcome
            // while its native AX call remains active. Do not call that quiescence;
            // the exact fixture is retired by defer, and this run is refused.
            throw QualificationError.accessibility(
                "Peekaboo AXPress did not settle; native work may still be running, so the effect is uncertain: \(error.localizedDescription)")
        }
        state.nativeQuiescence = "unverified-call-returned"
        guard action.payload.actionName == kAXPressAction as String,
              let outcome = action.outcome,
              outcome.delivery?.mechanism == .accessibilityAction,
              outcome.delivery?.mode == .background,
              outcome.evidence == .deliveryAccepted,
              outcome.evidence != .operationStillRunning,
              let target = action.targetIdentity?.exactWindow,
              target.identity == identity,
              target.bounds == window.bounds
        else {
            state.nativeQuiescence = "uncertain"
            throw QualificationError.accessibility(
                "Peekaboo AXPress did not return a completed background delivery acknowledgement; an operationStillRunning result is not quiescence.")
        }

        let actionReceiptIdentity = ActionReceiptIdentity(
            windowID: target.identity.windowID,
            processIdentifier: target.identity.ownerProcessIdentifier,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            bounds: target.bounds)
        let effectDeadline = ContinuousClock.now + .seconds(5)
        var afterCount = beforeCount
        while afterCount == beforeCount {
            try Task.checkCancellation()
            state.nativeQuiescence = "in-flight"
            let afterInspection = try await inspectFixtureWhenReady(
                automation, snapshots: snapshotManager, context: context, nonce: nonce, identity: identity,
                deadline: effectDeadline, sentinel: sentinelBefore, windowOrder: windowOrderBefore,
                requireScreenCapture: mode.captures)
            state.nativeQuiescence = "unverified-call-returned"
            afterCount = afterInspection.count
            if afterCount == beforeCount {
                if ContinuousClock.now >= effectDeadline {
                    throw QualificationError.effect("AXPress returned but the fixture action handler effect was not observed before the deadline.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        guard afterCount == 1 else { throw QualificationError.effect("Fixture effect counter changed unexpectedly: \(afterCount).") }
        state.effectState = "after-ax-observed"
        guard let currentWindow = exactWindow(pid: child.processIdentifier, title: title),
              currentWindow.id == window.id,
              currentWindow.bounds == window.bounds,
              SystemIdentityResolver.processStartIdentity(child.processIdentifier) == processStartIdentity
        else {
            throw QualificationError.identity("Fixture process/window/geometry changed after AXPress.")
        }
        guard let sentinelAfter = frontmostReceipt(), sentinelAfter == sentinelBefore else {
            throw QualificationError.identity("The independent frontmost-process sentinel changed during a background qualification run.")
        }
        try validateFixture(identity, title: title, bounds: window.bounds, requireScreenCapture: mode.captures)
        try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)
        let windowOrderAfterAX = normalWindowOrder()
        if mode.captures {
            state.nativeQuiescence = "in-flight"
            let after = try await captureService!.withCaptureEngine(.modern) {
                try await captureService!.captureWindow(
                    windowID: window.id, visualizerMode: .none, scale: .native)
            }
            state.nativeQuiescence = "unverified-call-returned"
            try validateFixture(identity, title: title, bounds: window.bounds, requireScreenCapture: true)
            try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)
            afterCapture = after
            afterMarker = try validateCapture(after, identity: identity, title: title, bounds: window.bounds)
            guard let beforeMarker, let afterMarker,
                  afterMarker.red > afterMarker.green * 2,
                  beforeMarker.green > beforeMarker.red * 2
            else {
                throw QualificationError.capture("Decoded exact-window captures did not show the fixture's green-to-red marker transition.")
            }
        }
        let windowOrderAfter = mode.captures ? normalWindowOrder() : windowOrderAfterAX
        try validateBackground(windowOrderBefore, sentinel: sentinelBefore, fixture: window.id)

        var screenshotReceipt: ScreenshotReceipt?
        if mode.captures {
            guard let beforeCapture, let afterCapture, let beforeMarker, let afterMarker,
                  let outputDirectory else {
                throw QualificationError.capture("Combined mode did not retain both exact-window captures.")
            }
            let beforeURL = outputDirectory.appendingPathComponent("before.png")
            let afterURL = outputDirectory.appendingPathComponent("after.png")
            try beforeCapture.imageData.write(to: beforeURL, options: .withoutOverwriting)
            try afterCapture.imageData.write(to: afterURL, options: .withoutOverwriting)
            screenshotReceipt = ScreenshotReceipt(
                beforePath: beforeURL.path,
                afterPath: afterURL.path,
                beforeBytes: beforeCapture.imageData.count,
                afterBytes: afterCapture.imageData.count,
                beforePixelSize: beforeCapture.metadata.size,
                afterPixelSize: afterCapture.metadata.size,
                beforeGreenMarkerSamples: beforeMarker.green,
                beforeRedMarkerSamples: beforeMarker.red,
                afterGreenMarkerSamples: afterMarker.green,
                afterRedMarkerSamples: afterMarker.red,
                captureEngine: beforeCapture.metadata.diagnostics?.engine ?? "modern")
        }
        guard retireOwnedFixture(child, termination: termination, stdin: stdinPipe) else {
            throw QualificationError.timeout("Owned fixture did not retire within the bounded cleanup deadline.")
        }
        childRetired = true
        let receipt = QualificationReport(
            hostGeneration: UUID(),
            mode: mode.argument,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
            processIdentifier: getpid(),
            parentProcessIdentifier: getppid(),
            accessibilityTrusted: true,
            screenCapturePreflight: CGPreflightScreenCaptureAccess(),
            guiSessionLocked: guiSessionLocked(),
            capabilities: mode.captures
                ? ["background-ax-exact-window-capture", "owned-app-effect-oracle"]
                : ["background-ax-exact-window-action", "owned-app-effect-oracle"],
            nativeActions: "background-axpress-confirmed",
            capture: mode.captures ? "exact-window-modern-screencapturekit" : "not-requested",
            fixture: FixtureReceipt(
                processIdentifier: child.processIdentifier,
                processStartIdentity: processStartIdentity,
                windowID: window.id,
                nonce: nonce,
                title: title,
                bounds: window.bounds,
                effectBefore: beforeCount,
                effectAfter: afterCount,
                nativeActionEvidence: action.outcome?.evidence.rawValue ?? "missing",
                actionReceiptIdentity: actionReceiptIdentity,
                retired: childRetired),
            screenshots: screenshotReceipt,
            foregroundSentinelBefore: sentinelBefore,
            foregroundSentinelAfter: sentinelAfter,
            backgroundNonActivationVerified: true,
            windowOrderBefore: windowOrderBefore, windowOrderAfter: windowOrderAfter)
        if mode.captures { state.effectState = "after-capture-observed" }
        guard state.deadline.disarm() else { _exit(124) }
        try write(receipt)
    }

    private static func runCaptureCoexistence() async throws {
        let state = try QualificationFailureState()
        do { try await captureCoexistenceAttempt(state: state) }
        catch {
            if state.deadline.disarm() { try? writeFailure(state.failure(error: error)) }
            throw error
        }
    }

    private static func captureCoexistenceAttempt(state: QualificationFailureState) async throws {
        try requireUnlockedGUI()
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(),
              let sentinel = frontmostReceipt(),
              let generation = SystemIdentityResolver.processStartIdentity(getpid()) else {
            throw QualificationError.capture("Capture fixture lacks permission or GUI identity.")
        }
        let beforeOrder = normalWindowOrder()
        guard !beforeOrder.isEmpty else { throw QualificationError.identity("No window-order sentinel.") }
        let nonce = UUID().uuidString
        let title = "Tron Qualification Fixture \(nonce)"
        let window = NSWindow(contentRect: NSRect(x: 240, y: 220, width: 520, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let marker = FixtureMarkerView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        window.title = title
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = marker
        window.orderBack(nil)
        window.displayIfNeeded()
        defer { window.close() }
        let readyDeadline = ContinuousClock.now + .seconds(3)
        var published: WindowReceipt?
        while published == nil, ContinuousClock.now < readyDeadline {
            published = exactWindow(pid: getpid(), title: title)
            if published == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard let owned = published, owned.id == window.windowNumber else {
            throw QualificationError.identity("Capture fixture window was not published; visible=\(window.isVisible), number=\(window.windowNumber).")
        }
        let identity = WindowMutationIdentity(windowID: Int(owned.id), ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation, capturedBounds: owned.bounds, isMinimized: false)
        state.target = identity
        let capture = ScreenCaptureService(loggingService: LoggingService(subsystem: "tron.qualification"))
        try validateFixture(identity, title: title, bounds: owned.bounds, requireScreenCapture: true)
        try validateBackground(beforeOrder, sentinel: sentinel, fixture: owned.id)
        state.nativeQuiescence = "in-flight"
        let before = try await capture.withCaptureEngine(.modern) {
            try await capture.captureWindow(windowID: owned.id, visualizerMode: .none, scale: .native)
        }
        state.nativeQuiescence = "unverified-call-returned"
        let green = try validateCapture(before, identity: identity, title: title, bounds: owned.bounds)
        guard green.green > green.red * 2 else { throw QualificationError.capture("Initial fixture was not green.") }
        // This is an app-owned test stimulus, not an executor action or a visual click.
        marker.isIncremented = true
        marker.needsDisplay = true
        marker.displayIfNeeded()
        state.effectState = "fixture-owned-colour-change"
        try validateFixture(identity, title: title, bounds: owned.bounds, requireScreenCapture: true)
        try validateBackground(beforeOrder, sentinel: sentinel, fixture: owned.id)
        state.nativeQuiescence = "in-flight"
        let after = try await capture.withCaptureEngine(.modern) {
            try await capture.captureWindow(windowID: owned.id, visualizerMode: .none, scale: .native)
        }
        state.nativeQuiescence = "unverified-call-returned"
        try validateFixture(identity, title: title, bounds: owned.bounds, requireScreenCapture: true)
        try validateBackground(beforeOrder, sentinel: sentinel, fixture: owned.id)
        let red = try validateCapture(after, identity: identity, title: title, bounds: owned.bounds)
        guard red.red > red.green * 2 else { throw QualificationError.capture("Captured fixture did not turn red.") }
        let afterOrder = normalWindowOrder()
        guard BackgroundWindowOrder.preserves(beforeOrder, current: afterOrder, fixture: owned.id) else {
            throw QualificationError.identity("Final capture window-order receipt changed.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-computer-use-qualification-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let beforeURL = directory.appendingPathComponent("before.png")
        let afterURL = directory.appendingPathComponent("after.png")
        try before.imageData.write(to: beforeURL, options: .withoutOverwriting)
        try after.imageData.write(to: afterURL, options: .withoutOverwriting)
        let report = CaptureCoexistenceReport(controllerProcessIdentifier: getpid(),
            controllerProcessStartIdentity: generation, executablePath: state.executablePath,
            windowID: owned.id, nonce: nonce, bounds: owned.bounds,
            beforePath: beforeURL.path, afterPath: afterURL.path,
            beforeGreenSamples: green.green, afterRedSamples: red.red,
            windowOrderBefore: beforeOrder, windowOrderAfter: afterOrder)
        guard state.deadline.disarm() else { _exit(124) }
        FileHandle.standardOutput.write(try JSONEncoder().encode(report) + Data("\n".utf8))
    }

    private static func exactWindow(pid: pid_t, title: String) -> WindowReceipt? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return raw.compactMap { (item: [String: Any]) -> WindowReceipt? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowName as String] as? String) == title,
                  let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds),
                  bounds.width > 0, bounds.height > 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber
            else { return nil }
            return WindowReceipt(id: CGWindowID(number.uint32Value), bounds: bounds)
        }.first
    }

    private static func retireOwnedFixture(
        _ child: Process,
        termination: DispatchSemaphore,
        stdin: Pipe) -> Bool
    {
        // Closing only our pipe authorizes only its exact reader to exit. Even
        // if AppKit/AX is blocked, the fixture's independent EOF thread exits it.
        // There is deliberately no PID-directed fallback.
        try? stdin.fileHandleForWriting.close()
        if !child.isRunning { return true }
        guard termination.wait(timeout: .now() + 5) == .success else { return false }
        return !child.isRunning
    }

    private static func writeFailure(_ report: FailureReceipt) throws {
        let data = try JSONEncoder().encode(report)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func inspectFixtureWhenReady(
        _ automation: UIAutomationService, snapshots: InMemorySnapshotManager,
        context: WindowContext, nonce: String,
        identity: WindowMutationIdentity, deadline: ContinuousClock.Instant,
        sentinel: FrontmostReceipt, windowOrder: [CGWindowID], requireScreenCapture: Bool
    ) async throws -> InspectedFixture {
        guard let bounds = context.windowBounds else {
            throw QualificationError.identity("AX readiness requires the exact captured window bounds.")
        }
        var lastDiagnostic = "No observation completed"
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw QualificationError.timeout("AX readiness expired: \(lastDiagnostic); OS oracle: \(fixtureAXDiagnostic(identity.ownerProcessIdentifier, title: "Tron Qualification Fixture \(nonce)"))")
            }
            try validateFixture(identity, title: "Tron Qualification Fixture \(nonce)",
                bounds: bounds, requireScreenCapture: requireScreenCapture)
            try validateBackground(windowOrder, sentinel: sentinel, fixture: CGWindowID(identity.windowID))
            do {
                return try await inspectFixture(automation, snapshots: snapshots, context: context, nonce: nonce, identity: identity)
            } catch QualificationError.accessibilityNotReady(let diagnostic) {
                lastDiagnostic = diagnostic
                // WindowServer readiness does not guarantee that AppKit has
                // published its AX subtree. Repeat only fresh observations;
                // identity refusals and every mutation remain non-replayed.
                guard ContinuousClock.now < deadline else {
                    throw QualificationError.timeout("Owned AX controls never became ready: \(diagnostic); OS oracle: \(fixtureAXDiagnostic(identity.ownerProcessIdentifier, title: "Tron Qualification Fixture \(nonce)"))")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Failure-only independent AX read oracle, restricted to the owned nonce
    /// window. This never performs an action or supplies a substitute executor.
    private static func fixtureAXDiagnostic(_ pid: pid_t, title: String) -> String {
        let deadline = ContinuousClock.now + .seconds(1)
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement],
              let window = windows.first(where: { attribute($0, kAXTitleAttribute as CFString) as? String == title })
        else { return "owned-window-unavailable" }
        var queue = [window]
        var result: [String] = []
        var index = 0
        while index < queue.count, index < 32, ContinuousClock.now < deadline {
            let element = queue[index]
            index += 1
            let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? "unknown"
            let label = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
            result.append("\(role):\(String(label.prefix(64)))")
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 32 - queue.count)))
            }
        }
        return result.joined(separator: "; ")
    }

    private static func inspectFixture(
        _ automation: UIAutomationService,
        snapshots: InMemorySnapshotManager,
        context: WindowContext,
        nonce: String,
        identity: WindowMutationIdentity) async throws -> InspectedFixture
    {
        let validBefore = SystemIdentityResolver.validateWindowMutationIdentity(identity)
        let result: ElementDetectionResult
        do {
            // Inspection-only UUIDs are not mutation authority. Allocate through
            // the native snapshot owner, then use the publication-capable AX
            // detector. Its native AX path does not consume image pixels.
            let snapshotID = try await snapshots.createSnapshot()
            result = try await automation.detectElements(
                in: Data(), snapshotId: snapshotID, windowContext: context)
        } catch {
            // Capture only the owned target's numeric geometry/identity before
            // cleanup. Preserve the original refusal; never relax or retry it.
            let live = SystemIdentityResolver.windowIdentity(CGWindowID(identity.windowID))
            throw QualificationError.accessibility(
                "Native AX refused: \(error.localizedDescription); receiptValidBefore=\(validBefore); " +
                "expectedBounds=\(String(describing: identity.capturedBounds)); liveBounds=\(String(describing: live?.bounds)); " +
                "expectedPID=\(identity.ownerProcessIdentifier); livePID=\(String(describing: live?.ownerProcessIdentifier)); " +
                "generationMatches=\(SystemIdentityResolver.processStartIdentity(identity.ownerProcessIdentifier) == identity.ownerProcessStartIdentity)")
        }
        guard let observed = result.metadata.windowContext,
              observed.windowID == identity.windowID,
              observed.applicationProcessId == identity.ownerProcessIdentifier,
              observed.applicationProcessStartIdentity == identity.ownerProcessStartIdentity,
              observed.windowMutationIdentity == identity,
              !result.metadata.isApplicationScopedAccessibilityFallback
        else {
            throw QualificationError.accessibility("Peekaboo AX inspection did not retain the exact fixture process/window receipt.")
        }
        let expectedTitle = "Increment \(nonce)"
        guard let button = result.elements.buttons.first(where: {
            $0.label == expectedTitle && $0.isEnabled && $0.isActionable
        }) else {
            let buttons = result.elements.buttons.prefix(12).map {
                "\(String(($0.label ?? "nil").prefix(80))) enabled=\($0.isEnabled) actionable=\($0.isActionable)"
            }.joined(separator: "; ")
            throw QualificationError.accessibilityNotReady(
                "Owned fixture button missing; elements=\(result.elements.all.count); " +
                "truncation=\(String(describing: result.metadata.truncationInfo)); buttons=\(buttons)")
        }
        let labels = result.elements.all.filter {
            ($0.value ?? $0.label ?? "").hasPrefix("count:")
        }
        guard let label = labels.first,
              let value = label.value ?? label.label,
              let count = Int(value.dropFirst("count:".count))
        else {
            throw QualificationError.accessibilityNotReady("Fixture effect label could not be read through Peekaboo AX inspection.")
        }
        return InspectedFixture(snapshotId: result.snapshotId, button: button, count: count)
    }

    private static func validateCapture(
        _ capture: CaptureResult,
        identity: WindowMutationIdentity,
        title: String,
        bounds: CGRect) throws -> MarkerEvidence
    {
        guard capture.metadata.windowInfo?.windowID == identity.windowID,
              capture.metadata.windowInfo?.title == title,
              capture.metadata.windowInfo?.mutationIdentity == identity,
              capture.metadata.windowInfo?.bounds == bounds,
              capture.metadata.applicationInfo?.processIdentifier == identity.ownerProcessIdentifier,
              capture.metadata.applicationInfo?.processStartIdentity == identity.ownerProcessStartIdentity,
              capture.metadata.diagnostics?.engine == "ScreenCaptureKit"
        else { throw QualificationError.capture("Capture metadata did not retain the exact fixture window/process/geometry or modern engine provenance.") }
        guard !capture.imageData.isEmpty, capture.imageData.count <= 2 * 1_024 * 1_024 else {
            throw QualificationError.capture("Exact-window encoded image is outside the fixture byte bound.")
        }
        guard let source = CGImageSourceCreateWithData(capture.imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2_560, height <= 2_560,
              width * height <= 4_000_000,
              CGSize(width: width, height: height) == capture.metadata.size,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw QualificationError.capture("Exact-window capture bytes were not a decodable image.") }
        let samples = try QualificationMarkerOracle.samples(in: image)
        let green = samples.green
        let red = samples.red
        guard green + red > 100 else {
            // Scope/identity/size were verified above. Retain this explicit
            // fixture diagnostic so a marker failure is inspectable, not retried
            // blindly or hidden by a weaker colour assertion.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tron-fixture-marker-diagnostic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let diagnostic = directory.appendingPathComponent("capture.png")
            try capture.imageData.write(to: diagnostic, options: .withoutOverwriting)
            throw QualificationError.capture(
                "Decoded exact-window marker missing: green=\(green), red=\(red), pixels=\(image.width)x\(image.height); diagnostic=\(diagnostic.path)")
        }
        return MarkerEvidence(green: green, red: red)
    }

    private static func validateFixture(
        _ identity: WindowMutationIdentity,
        title: String,
        bounds: CGRect,
        requireScreenCapture: Bool
    ) throws {
        try requireUnlockedGUI()
        guard AXIsProcessTrusted(), (!requireScreenCapture || CGPreflightScreenCaptureAccess()) else {
            throw QualificationError.identity("Native permission was revoked during the fixture; no new operation is admitted.")
        }
        guard SystemIdentityResolver.processStartIdentity(identity.ownerProcessIdentifier) == identity.ownerProcessStartIdentity,
              let window = exactWindow(pid: identity.ownerProcessIdentifier, title: title),
              window.id == identity.windowID, window.bounds == bounds
        else { throw QualificationError.identity("Exact fixture identity/nonce/geometry changed before or after native capture.") }
    }

    private static func normalWindowOrder() -> [CGWindowID] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let value = row[kCGWindowNumber as String] as? NSNumber else { return nil }
            return value.uint32Value
        }
    }

    private static func validateBackground(_ before: [CGWindowID], sentinel: FrontmostReceipt, fixture: CGWindowID) throws {
        guard frontmostReceipt() == sentinel,
              BackgroundWindowOrder.preserves(before, current: normalWindowOrder(), fixture: fixture)
        else { throw QualificationError.identity("Background fixture changed focus/window order, or independent user/window activity invalidated the sentinel.") }
    }

    private static func frontmostReceipt() -> FrontmostReceipt? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let identity = SystemIdentityResolver.processStartIdentity(application.processIdentifier)
        else { return nil }
        return FrontmostReceipt(
            processIdentifier: application.processIdentifier,
            processStartIdentity: identity,
            bundleIdentifier: application.bundleIdentifier)
    }

    private static func write(_ report: QualificationReport) throws {
        let data = try JSONEncoder().encode(report)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

private struct WindowReceipt {
    let id: CGWindowID
    let bounds: CGRect
}

private struct InspectedFixture {
    let snapshotId: String
    let button: DetectedElement
    let count: Int
}
