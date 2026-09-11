import AppKit
import Foundation
import TronComputerControl

@MainActor
private final class CaptureMarkerView: NSView {
    var stage = CaptureQualificationStage.initial
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Deliberately independent of the JPEG oracle's numeric expectations.
        let colors: [NSColor]
        switch stage {
        case .initial: colors = [.init(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                 .init(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                 .init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                                 .init(srgbRed: 1, green: 1, blue: 0, alpha: 1)]
        case .changed: colors = [.init(srgbRed: 0, green: 1, blue: 1, alpha: 1),
                                 .init(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                                 .init(srgbRed: 1, green: 1, blue: 0, alpha: 1),
                                 .init(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
        case .resized, .sourceCloseBaseline:
            colors = [.init(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                      .init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                      .init(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                      .init(srgbRed: 0, green: 1, blue: 1, alpha: 1)]
        }
        for index in 0..<4 {
            colors[index].setFill()
            NSRect(x: CGFloat(index % 2) * bounds.width / 2, y: CGFloat(index / 2) * bounds.height / 2,
                   width: bounds.width / 2, height: bounds.height / 2).fill()
        }
    }
}

@MainActor
private final class CaptureFixtureWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private let marker = CaptureMarkerView()

    init() {
        super.init(contentRect: NSRect(x: 80, y: 80, width: 320, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isFloatingPanel = false; hidesOnDeactivate = false
        level = .normal; hasShadow = false; isOpaque = true; animationBehavior = .none
        ignoresMouseEvents = true; isMovable = false
        contentView = marker
    }

    func present(_ stage: CaptureQualificationStage) {
        marker.stage = stage
        // Fixture geometry is independent of the evidence oracle's point sizes.
        switch stage {
        case .initial, .changed: setContentSize(NSSize(width: 320, height: 200))
        case .resized, .sourceCloseBaseline: setContentSize(NSSize(width: 200, height: 320))
        }
        marker.needsDisplay = true
        // Ordering only this non-key, nonactivating panel never activates an app
        // or restores another application's focus. Actual pixels, not this call's
        // return or a rendering delay, establish the qualification stage.
        orderFrontRegardless()
        marker.display()
        displayIfNeeded()
    }
}

/// Cancellation closes admission without cancelling/abandoning the native join.
/// It also fences the gap around selection and between the two stream lifetimes.
private final class CaptureQualificationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var active: NativeWindowCapture?
    private var deadline = false
    private var cancelled = false

    func attach(_ producer: NativeWindowCapture) {
        let stop = lock.withLock { active = producer; return deadline || cancelled }
        if stop { producer.requestStop() }
    }
    func detach() { lock.withLock { active = nil } }
    func stop(deadline: Bool) {
        let producer = lock.withLock {
            if deadline { self.deadline = true } else { cancelled = true }
            return active
        }
        producer?.requestStop()
    }
    var snapshot: (deadline: Bool, cancelled: Bool) { lock.withLock { (deadline, cancelled) } }
    func check() throws {
        let state = snapshot
        if state.deadline { throw CaptureQualificationFailure.deadline }
        if state.cancelled || Task.isCancelled { throw CaptureQualificationFailure.cancelled }
    }
}

@MainActor
final class CaptureQualificationLifecycle {
    // If the producer reports failed removal, the app stays alive retaining the
    // exact failed resource. Only the parent can decide containment; process exit
    // or a timer cannot manufacture joined native retirement.
    private var retainedProducers: [NativeWindowCapture] = []
    private var inspectedFrames = 0

    static func preflight() -> CaptureQualificationReport {
        var report = CaptureQualificationReport(mode: "preflight")
        if #available(macOS 15.2, *) { report.supportedSystem = true }
        // Never call a request API, SCK enumeration, NSApplication, or a stream.
        report.screenRecordingPreflight = CGPreflightScreenCaptureAccess()
        if !report.supportedSystem { report.failure = .unsupportedSystem }
        else if !report.screenRecordingPreflight { report.failure = .permissionUnavailable }
        return report
    }

    func run(writeImages: Bool) async -> CaptureQualificationReport {
        let control = CaptureQualificationControl()
        return await withTaskCancellationHandler {
            await execute(writeImages: writeImages, control: control)
        } onCancel: { control.stop(deadline: false) }
    }

    private func execute(writeImages: Bool, control: CaptureQualificationControl) async -> CaptureQualificationReport {
        var report = CaptureQualificationReport(mode: "capture-self-window")
        if control.snapshot.cancelled || Task.isCancelled {
            report.cancellationObserved = true; report.failure = .cancelled
            return report
        }
        let preflight = Self.preflight()
        report.supportedSystem = preflight.supportedSystem
        report.screenRecordingPreflight = preflight.screenRecordingPreflight
        report.failure = preflight.failure
        guard preflight.passed else { return report }
        let deadline = Task.detached {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            control.stop(deadline: true)
        }
        var fixture: CaptureFixtureWindow?
        var active: NativeWindowCapture?
        var secondLifetime = false
        do {
            try control.check()
            let application = NSRunningApplication.current
            guard application.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  !application.isTerminated, application.launchDate != nil else {
                throw CaptureQualificationFailure.identityUnavailable
            }
            let images = try writeImages ? CaptureQualificationImages() : nil
            report.imageDirectory = images?.path
            let window = CaptureFixtureWindow(); fixture = window
            window.present(.initial)
            guard window.windowNumber > 0, window.windowNumber <= Int(UInt32.max), !window.isKeyWindow, !window.isMainWindow else {
                throw CaptureQualificationFailure.identityUnavailable
            }
            let selection = try await NativeWindowCaptureSelection.select(windowID: UInt32(window.windowNumber), application: application)
            try control.check()
            let producer = NativeWindowCapture(selection: selection, limits: try .init())
            active = producer; retainedProducers.append(producer); control.attach(producer)
            let generation = try await start(producer, control: control)
            for stage in [CaptureQualificationStage.initial, .changed, .resized] {
                try control.check()
                window.present(stage)
                report.frames.append(try await frame(producer, generation: generation, stage: stage, images: images, control: control))
            }
            let stopped = await CaptureQualificationStopInspection.observe(producer, generation: generation)
            report.stopJoined = stopped.joined
            report.retirementFailure = stopped.retirementFailure.map { String(describing: $0) }
            report.lateReadRejected = stopped.readFailure == .stopped
            try stopped.require(expected: .stopped)
            active = nil; control.detach()
            try control.check()

            // A stopped stream cannot prove source-close behavior. Start a second
            // single-use producer on the SAME retained, own-window selection.
            secondLifetime = true
            let source = NativeWindowCapture(selection: selection, limits: try .init())
            active = source; retainedProducers.append(source); control.attach(source)
            let sourceGeneration = try await start(source, control: control)
            report.frames.append(try await frame(source, generation: sourceGeneration, stage: .sourceCloseBaseline,
                                                 images: images, control: control))
            try control.check()
            window.close()
            let closeReason = try await observeSourceClose(source, generation: sourceGeneration, control: control)
            report.sourceCloseReason = String(describing: closeReason)
            report.sourceCloseObserved = true
            let stoppedSource = await CaptureQualificationStopInspection.observe(source, generation: sourceGeneration)
            report.sourceStopJoined = stoppedSource.joined
            report.retirementFailure = stoppedSource.retirementFailure.map { String(describing: $0) }
            report.sourceLateReadRejected = stoppedSource.readFailure == closeReason
            try stoppedSource.require(expected: closeReason)
            active = nil; control.detach()
            try control.check()
        } catch {
            report.failure = error as? CaptureQualificationFailure
                ?? (error is CancellationError ? .cancelled : .nativeUnavailable)
            if let native = error as? NativeWindowCaptureError { report.nativeFailure = String(describing: native) }
        }
        if let active {
            active.requestStop()
            let joined = await active.stopAndJoin() == .joined
            if let diagnostic = active.retirementFailure { report.retirementFailure = String(describing: diagnostic) }
            if secondLifetime { report.sourceStopJoined = joined } else { report.stopJoined = joined }
            report.containmentRequired = !joined
            control.detach()
        }
        fixture?.close()
        deadline.cancel()
        await deadline.value // Freeze flags only after the timer's actual completion.
        let state = control.snapshot
        report.deadlineTriggered = state.deadline; report.cancellationObserved = state.cancelled || Task.isCancelled
        if state.deadline { report.failure = .deadline }
        else if report.cancellationObserved { report.failure = .cancelled }
        if report.failure == nil && !report.passed { report.failure = .dimensionsMismatch }
        return report
    }

    private func start(_ producer: NativeWindowCapture, control: CaptureQualificationControl) async throws -> UUID {
        let result = await producer.start()
        try control.check()
        switch result {
        case let .available(generation): return generation
        case let .unavailable(error): throw error
        }
    }

    private func frame(_ producer: NativeWindowCapture, generation: UUID, stage: CaptureQualificationStage,
                       images: CaptureQualificationImages?, control: CaptureQualificationControl) async throws -> CaptureQualificationFrameEvidence {
        while true {
            try control.check()
            if let frame = try producer.takeLatestFrame(generation: generation) {
                inspectedFrames += 1
                guard inspectedFrames <= 100 else { throw CaptureQualificationFailure.frameBudget }
                let evidence = try autoreleasepool { try CaptureQualificationJPEG.inspect(frame, stage: stage) }
                guard frame.generation == generation else { throw CaptureQualificationFailure.nativeUnavailable }
                if evidence.matches {
                    try control.check()
                    try images?.write(frame.jpeg, stage: stage)
                    return evidence
                }
                // An earlier complete frame may precede the controlled redraw.
                // It cannot pass the new marker oracle and is discarded, not kept.
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func observeSourceClose(_ producer: NativeWindowCapture, generation: UUID,
                                    control: CaptureQualificationControl) async throws -> NativeWindowCaptureError {
        while true {
            try control.check()
            do { _ = try producer.takeLatestFrame(generation: generation) }
            catch let error as NativeWindowCaptureError {
                try control.check() // A deadline-induced Stop is NOT source-close evidence.
                switch error {
                case .sourceUnavailable, .streamFailed: return error
                default: throw CaptureQualificationFailure.sourceCloseNotObserved
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

}
