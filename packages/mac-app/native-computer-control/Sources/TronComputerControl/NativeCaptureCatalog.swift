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
    public enum Kind: String, Sendable { case window, display }
    public let kind: Kind
    public let applicationName: String
    public let title: String
    public let width: Double
    public let height: Double
    private let selection: NativeWindowCaptureSelection

    internal init(selection: NativeWindowCaptureSelection, kind: Kind, size: CGSize, applicationName: String, title: String) {
        self.selection = selection; self.kind = kind
        width = Double(size.width); height = Double(size.height)
        self.applicationName = NativeCaptureText.bounded(applicationName)
        self.title = NativeCaptureText.bounded(title)
    }

    public func makeStream(region: NativeCaptureRegion? = nil, admission: @escaping @Sendable () -> Bool) throws -> NativeCaptureStream {
        guard admission() else { throw NativeWindowCaptureError.stopped }
        let selected = try region.map { try selection.cropped(to: $0) } ?? selection
        return try NativeCaptureStream(selection: selected, admission: admission)
    }
}

public enum NativeCaptureCatalog {
    public static let maximumSources = 32

    /// SCK includes inactive layer-zero utility/menu surfaces in its all-window
    /// inventory. They cannot serve the visible-window picker and can consume
    /// the entire bounded catalog before actual app windows are considered.
    internal static func admitsWindow(layer: Int, onScreen: Bool, frame: CGRect) -> Bool {
        onScreen && layer == 0 && !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite && frame.size.width > 0 && frame.size.height > 0
    }

    /// Explicit, bounded, transient inventory. Identity is captured before the
    /// SDK await; new/replaced applications cannot enter this result afterward.
    public static func load(admission: @escaping @Sendable () -> Bool) async throws -> [NativeCaptureSource] {
        guard #available(macOS 15.2, *) else { throw NativeWindowCaptureError.unsupportedSystem }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        let displays = try NativeCaptureDisplayIdentity.active()
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> (NSRunningApplication, Date, WindowCaptureProcessIdentity)? in
            guard !app.isTerminated, let launch = app.launchDate,
                  let identity = try? WindowCaptureProcessIdentity.read(pid: app.processIdentifier) else { return nil }
            return (app, launch, identity)
        }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch { throw NativeWindowCaptureError.sourceUnavailable }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        guard CGPreflightScreenCaptureAccess() else { throw NativeWindowCaptureError.permissionUnavailable }
        var sources: [NativeCaptureSource] = []
        let mainDisplay = CGMainDisplayID()
        let orderedDisplays = content.displays.sorted {
            if ($0.displayID == mainDisplay) != ($1.displayID == mainDisplay) { return $0.displayID == mainDisplay }
            return $0.displayID < $1.displayID
        }
        for display in orderedDisplays {
            guard sources.count < maximumSources else { break }
            guard admission() else { throw NativeWindowCaptureError.stopped }
            guard let identity = displays.first(where: { $0.id == display.displayID }),
                  (try? NativeCaptureDisplayIdentity.read(identity.id)) == identity,
                  let selection = try? NativeWindowCaptureSelection(display: display, identity: identity) else { continue }
            sources.append(NativeCaptureSource(selection: selection, kind: .display,
                size: CGSize(width: identity.width, height: identity.height), applicationName: "Mac",
                title: identity.id == mainDisplay ? "Main display" : "Display \(sources.count + 1)"))
        }
        for window in content.windows {
            guard sources.count < maximumSources else { break }
            guard admission() else { throw NativeWindowCaptureError.stopped }
            guard window.windowID != 0,
                  admitsWindow(layer: window.windowLayer, onScreen: window.isOnScreen, frame: window.frame),
                  let (app, launch, identity) = applications.first(where: { $0.2.pid == window.owningApplication?.processID }),
                  !app.isTerminated, app.launchDate == launch,
                  (try? WindowCaptureProcessIdentity.read(pid: identity.pid)) == identity else { continue }
            guard let selection = try? NativeWindowCaptureSelection(application: app, launchDate: launch, process: identity, window: window) else { continue }
            sources.append(NativeCaptureSource(selection: selection, kind: .window, size: window.frame.size,
                applicationName: app.localizedName ?? "Application", title: window.title ?? ""))
        }
        guard admission() else { throw NativeWindowCaptureError.stopped }
        return sources
    }
}

/// Narrow public capture lifetime facade. No raw target selectors cross the
/// host boundary and no stream starts on construction.
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
