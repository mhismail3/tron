import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Display-only strings are bounded in bytes, not graphemes (one combining
/// cluster can otherwise be arbitrarily large). Invalid trailing UTF-8 is omitted.
public enum NativeCaptureText {
    public static func bounded(_ value: String) -> String {
        var bytes = Array(value.utf8.prefix(256))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}

/// The external host can enumerate capture-only sources, never supply a PID or
/// window ID. Each source retains the initially observed SCK object/filter.
public final class NativeCaptureSource: Sendable {
    public let applicationName: String
    public let title: String
    private let selection: NativeWindowCaptureSelection

    internal init(selection: NativeWindowCaptureSelection, applicationName: String, title: String) {
        self.selection = selection
        self.applicationName = NativeCaptureText.bounded(applicationName)
        self.title = NativeCaptureText.bounded(title)
    }

    public func makeStream(admission: @escaping @Sendable () -> Bool) throws -> NativeCaptureStream {
        guard admission() else { throw NativeWindowCaptureError.stopped }
        return try NativeCaptureStream(selection: selection, admission: admission)
    }
}

public enum NativeCaptureCatalog {
    public static let maximumSources = 32

    /// Explicit, bounded, transient inventory. Identity is captured before the
    /// SDK await; new/replaced applications cannot enter this result afterward.
    public static func load(admission: @escaping @Sendable () -> Bool) async throws -> [NativeCaptureSource] {
        guard #available(macOS 15.2, *) else { throw NativeWindowCaptureError.unsupportedSystem }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> (NSRunningApplication, Date, WindowCaptureProcessIdentity)? in
            guard !app.isTerminated, let launch = app.launchDate,
                  let identity = try? WindowCaptureProcessIdentity.read(pid: app.processIdentifier) else { return nil }
            return (app, launch, identity)
        }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw NativeWindowCaptureError.sourceUnavailable }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        var sources: [NativeCaptureSource] = []
        for window in content.windows {
            guard sources.count < maximumSources else { break }
            guard admission() else { throw NativeWindowCaptureError.stopped }
            guard window.windowID != 0, window.windowLayer == 0,
                  window.frame.origin.x.isFinite, window.frame.origin.y.isFinite,
                  window.frame.size.width.isFinite, window.frame.size.height.isFinite,
                  window.frame.size.width > 0, window.frame.size.height > 0,
                  let (app, launch, identity) = applications.first(where: { $0.2.pid == window.owningApplication?.processID }),
                  !app.isTerminated, app.launchDate == launch,
                  (try? WindowCaptureProcessIdentity.read(pid: identity.pid)) == identity else { continue }
            let selection = try NativeWindowCaptureSelection(application: app, launchDate: launch, process: identity, window: window)
            sources.append(NativeCaptureSource(selection: selection, applicationName: app.localizedName ?? "Application", title: window.title ?? ""))
        }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        return sources
    }
}

/// Narrow public lifetime facade; input, interlock, platform injection and raw
/// target selectors stay inside the package. No stream starts on construction.
public final class NativeCaptureStream: Sendable {
    private let owner: NativeWindowCapture
    internal init(selection: NativeWindowCaptureSelection, admission: @escaping @Sendable () -> Bool) throws {
        owner = NativeWindowCapture(platform: AdmittedCapturePlatform(selection: selection, admission: admission),
                                    limits: try NativeWindowCaptureLimits())
    }
    public func start() async -> NativeWindowCaptureAvailability { await owner.start() }
    public func takeLatestFrame(generation: UUID) throws -> NativeWindowCaptureFrame? { try owner.takeLatestFrame(generation: generation) }
    public func requestStop() { owner.requestStop() }
    public func stopAndJoin() async -> NativeWindowCaptureJoin { await owner.stopAndJoin() }
    public var retirementFailure: NativeWindowCaptureError? { owner.retirementFailure }
}

private struct AdmittedCapturePlatform: NativeWindowCapturePlatform {
    let selection: NativeWindowCaptureSelection
    let admission: @Sendable () -> Bool
    func validate() throws {
        guard admission() else { throw NativeWindowCaptureError.stopped }
        try ScreenCaptureKitPlatform(selection: selection).validate()
        guard admission() else { throw NativeWindowCaptureError.stopped }
    }
    func makeStream(limits: NativeWindowCaptureLimits, output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws -> any NativeWindowCaptureStream {
        try validate()
        return try ScreenCaptureKitPlatform(selection: selection).makeStream(limits: limits, output: output)
    }
}
