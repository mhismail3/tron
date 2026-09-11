import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// Kernel launch identity, not an exec incarnation, code identity, or input grant.
internal struct WindowCaptureProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func read(pid: Int32) throws -> Self {
        guard pid > 0 else { throw NativeWindowCaptureError.processUnavailable }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard count == size, info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000, info.pbi_status != SZOMB,
              info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 else {
            throw NativeWindowCaptureError.processUnavailable
        }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

/// Capture-only selection, never an input target. The exact SDK filter remains
/// private and is never updated, rediscovered, or widened after selection.
package final class NativeWindowCaptureSelection: @unchecked Sendable {
    private enum Content {
        case window(NSRunningApplication, Date, WindowCaptureProcessIdentity, SCWindow)
        case display(SCDisplay, NativeCaptureDisplayIdentity)
    }
    private let content: Content
    fileprivate let filter: SCContentFilter
    fileprivate let sourceRect: CGRect?

    internal init(application: NSRunningApplication, launchDate: Date,
                 process: WindowCaptureProcessIdentity, window: SCWindow) throws {
        content = .window(application, launchDate, process, window)
        sourceRect = nil
        filter = SCContentFilter(desktopIndependentWindow: window)
        try validate()
    }

    internal init(display: SCDisplay, identity: NativeCaptureDisplayIdentity,
                  region: NativeCaptureRegion? = nil) throws {
        guard display.displayID == identity.id else { throw NativeWindowCaptureError.sourceUnavailable }
        content = .display(display, identity)
        sourceRect = try region?.rectangle(in: CGSize(width: identity.width, height: identity.height))
        filter = SCContentFilter(display: display, excludingWindows: [])
        try validate()
    }

    internal func cropped(to region: NativeCaptureRegion) throws -> NativeWindowCaptureSelection {
        guard case let .display(display, identity) = content else { throw NativeWindowCaptureError.sourceUnavailable }
        return try Self(display: display, identity: identity, region: region)
    }

    /// One initial lookup only, guarded on both sides of the SDK await. No titles,
    /// inventory, or pixels are logged/retained beyond this exact selection.
    package static func select(windowID: CGWindowID, application: NSRunningApplication) async throws -> NativeWindowCaptureSelection {
        guard #available(macOS 15.2, *) else { throw NativeWindowCaptureError.unsupportedSystem }
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        guard windowID != 0 else { throw NativeWindowCaptureError.sourceUnavailable }
        guard !application.isTerminated, let launch = application.launchDate else {
            throw NativeWindowCaptureError.processUnavailable
        }
        let identity = try WindowCaptureProcessIdentity.read(pid: application.processIdentifier)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw NativeWindowCaptureError.sourceUnavailable }
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        guard !application.isTerminated, application.launchDate == launch,
              try WindowCaptureProcessIdentity.read(pid: identity.pid) == identity else {
            throw NativeWindowCaptureError.processUnavailable
        }
        let matches = content.windows.filter { $0.windowID == windowID && $0.owningApplication?.processID == identity.pid }
        guard matches.count == 1, let window = matches.first,
              NativeCaptureCatalog.admitsWindow(layer: window.windowLayer, onScreen: window.isOnScreen, frame: window.frame) else { throw NativeWindowCaptureError.sourceUnavailable }
        return try .init(application: application, launchDate: launch, process: identity, window: window)
    }

    fileprivate func validate() throws {
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        switch content {
        case let .window(application, launchDate, process, window):
            guard !application.isTerminated, application.launchDate == launchDate,
                  application.processIdentifier == process.pid,
                  try WindowCaptureProcessIdentity.read(pid: process.pid) == process else {
                throw NativeWindowCaptureError.processUnavailable
            }
            guard window.owningApplication?.processID == process.pid, filter.style == .window else {
                throw NativeWindowCaptureError.sourceUnavailable
            }
        case let .display(display, identity):
            let current = try NativeCaptureDisplayIdentity.read(display.displayID)
            // Whole-display streams can follow resolution changes. A selected
            // area cannot silently change coordinate spaces or expand its crop.
            guard filter.style == .display, identity.admits(current, cropped: sourceRect != nil) else {
                throw NativeWindowCaptureError.sourceUnavailable
            }
        }
    }
}

internal struct ScreenCaptureKitPlatform: NativeWindowCapturePlatform {
    let selection: NativeWindowCaptureSelection
    func validate() throws { try selection.validate() }
    func makeStream(limits: NativeWindowCaptureLimits,
                    output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws -> any NativeWindowCaptureStream {
        guard #available(macOS 15.2, *) else { throw NativeWindowCaptureError.unsupportedSystem }
        try validate()
        return try ScreenCaptureKitWindowStream(selection: selection, limits: limits, output: output)
    }

    // Inert configuration construction is covered offline; no native start here.
    static func configuration(_ limits: NativeWindowCaptureLimits, sourceRect: CGRect? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = limits.width; config.height = limits.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(limits.framesPerSecond))
        config.queueDepth = NativeWindowCaptureLimits.queueDepth
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureDynamicRange = .SDR
        config.preservesAspectRatio = true; config.scalesToFit = true
        config.showsCursor = false; config.showMouseClicks = false
        config.capturesAudio = false; config.captureMicrophone = false
        config.includeChildWindows = false; config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.presenterOverlayPrivacyAlertSetting = .never
        return config
    }
}

/// The owner serializes start -> stop. Sample work stays synchronous on one SCK
/// queue, with bounded encoding and no per-frame dispatch/tasks. The callback
/// gate also joins delegate callbacks (SCK does not give them a caller queue).
@available(macOS 15.2, *)
private final class ScreenCaptureKitWindowStream: NSObject, NativeWindowCaptureStream, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lifetime = WindowCaptureStreamLifetime()
    private let sampleQueue = DispatchQueue(label: "com.tron.window-capture.samples", qos: .utility)
    private let selection: NativeWindowCaptureSelection
    private let encoder: WindowCaptureJPEGEncoder
    private let output: @Sendable (NativeWindowCaptureOutput) -> Void
    private var native: SCStream!
    var retirementFailure: NativeWindowCaptureError? { lifetime.retirementFailure }

    init(selection: NativeWindowCaptureSelection, limits: NativeWindowCaptureLimits,
         output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws {
        self.selection = selection; encoder = WindowCaptureJPEGEncoder(limits: limits); self.output = output
        super.init()
        let configuration = ScreenCaptureKitPlatform.configuration(limits, sourceRect: selection.sourceRect)
        native = SCStream(filter: selection.filter, configuration: configuration, delegate: self)
        try native.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    }

    func start() async throws {
        try selection.validate()
        guard lifetime.beginStart() else { throw NativeWindowCaptureError.stopped }
        do { try await native.startCapture() }
        catch { throw NativeWindowCaptureError.streamFailed }
        try selection.validate()
        guard !lifetime.isClosed else { throw NativeWindowCaptureError.stopped }
    }

    func requestStop() { lifetime.requestStop() }

    func stopAndJoin() async -> NativeWindowCaptureJoin {
        await lifetime.stopAndJoin(
            stop: { [self] in try await native.stopCapture() },
            removeOutput: { [self] in try native.removeStreamOutput(self, type: .screen) },
            sampleQueue: sampleQueue)
    }
    private func fail(_ error: NativeWindowCaptureError) {
        requestStop()
        output(.failed(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lifetime.withCallback { _ in
            guard stream === native, type == .screen else { fail(.malformedFrame); return }
            do {
                try selection.validate()
                let frame = try autoreleasepool { try encoder.encode(sampleBuffer) }
                guard let frame, !lifetime.isClosed else { return }
                try selection.validate()
                output(.frame(jpeg: frame.jpeg, width: frame.width, height: frame.height))
            } catch { fail(error as? NativeWindowCaptureError ?? .malformedFrame) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard stream === native else { return }
        lifetime.withCallback(terminal: true) { mayPublish in
            if mayPublish { fail(.streamFailed) }
        }
    }
    func streamDidBecomeInactive(_ stream: SCStream) {
        guard stream === native else { return }
        lifetime.withCallback { _ in fail(.sourceUnavailable) } // Never resume/rebind.
    }
    func outputVideoEffectDidStart(for stream: SCStream) {
        guard stream === native else { return }
        lifetime.withCallback { _ in fail(.sourceUnavailable) } // No overlay pixels.
    }
}
