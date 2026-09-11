import AppKit
import TronNativeCaptureHost
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

/// XPC delivers on connection queues. Marshal every GUI/TCC operation to the
/// main queue; no permission state is shared across those queues or persisted.
private final class NativePermissionService: NSObject, NativeHostPermissionService, @unchecked Sendable {
    private var receipts = NativePermissionRequestReceipts()
    private let captures: NativeCaptureSlot
    init(captures: NativeCaptureSlot) { self.captures = captures }
    func prepareForServiceRetirement(withReply reply: @escaping @Sendable (Bool) -> Void) {
        Task { reply(await captures.drainForServiceRetirement()) }
    }
    func probePermissions(withReply reply: @escaping @Sendable ([String: String]) -> Void) {
        DispatchQueue.main.async { reply(Self.snapshot()) }
    }

    func requestPermission(_ raw: String, requestID: String,
                           withReply reply: @escaping @Sendable (String, String) -> Void) {
        guard let permission = NativeHostPermission(rawValue: raw), let id = UUID(uuidString: requestID) else {
            reply("", NativeHostPermissionStatus.probeUnavailable.rawValue)
            return
        }
        DispatchQueue.main.async {
            if let status = self.receipts.cachedStatus(for: permission, id: id) { reply(requestID, status); return }
            guard Self.guiSessionAvailable else {
                reply(requestID, NativeHostPermissionStatus.probeUnavailable.rawValue); return
            }
            switch permission {
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .inputMonitoring: _ = CGRequestListenEventAccess()
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            }
            // A false request/preflight is not proof of explicit denial: AX may
            // have just opened Settings. Always report the current native state.
            let status = Self.snapshot()[permission.rawValue] ?? NativeHostPermissionStatus.probeUnavailable.rawValue
            self.receipts.record(status, for: permission, id: id)
            reply(requestID, status)
        }
    }

    private static var guiSessionAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
            && session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
    }

    private static func snapshot() -> [String: String] {
        guard guiSessionAvailable else {
            return Dictionary(uniqueKeysWithValues: NativeHostPermission.allCases.map {
                ($0.rawValue, NativeHostPermissionStatus.probeUnavailable.rawValue)
            })
        }
        let grants: [NativeHostPermission: Bool] = [
            .accessibility: AXIsProcessTrusted(), .inputMonitoring: CGPreflightListenEventAccess(),
            .screenRecording: CGPreflightScreenCaptureAccess()
        ]
        return Dictionary(uniqueKeysWithValues: grants.map {
            ($0.key.rawValue, ($0.value ? NativeHostPermissionStatus.granted : .notDetermined).rawValue)
        })
    }
}

private final class NativeHostDelegate: NSObject, NSXPCListenerDelegate {
    private let service: NativePermissionService
    private let requirement: String
    init(requirement: String, captures: NativeCaptureSlot) {
        self.requirement = requirement; service = NativePermissionService(captures: captures)
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NativeHostPermissionService.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

@MainActor
private enum NativeHostMain {
    static func run() {
        do {
            let ownBundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
            var parentBundle = ownBundle
            for _ in 0..<4 { parentBundle.deleteLastPathComponent() }
            guard parentBundle.pathExtension == "app",
                  parentBundle.appendingPathComponent(NativeHostTrust.relativeBundlePath).resolvingSymlinksInPath() == ownBundle else {
                throw NativeHostTrustError.invalidIdentity
            }
            let requirement = try NativeCodeSigning.pin(NativeHostTrust.wrapperCodeSigningRequirement, to: parentBundle)
            let listener = NSXPCListener(machServiceName: NativeHostTrust.machServiceName)
            let captures = NativeCaptureSlot()
            let delegate = NativeHostDelegate(requirement: requirement, captures: captures)
            guard let team = Bundle.main.object(forInfoDictionaryKey: "TronSigningTeam") as? String,
                  team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw NativeHostTrustError.invalidIdentity }
            let teamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            let captureListener = NSXPCListener(machServiceName: NativeHostTrust.captureMachServiceName)
            let captureDelegate = NativeCaptureListener(slot: captures,
                context: NativeCaptureContext(outerBundle: parentBundle, teamRequirement: teamRequirement))
            captureListener.delegate = captureDelegate
            captureListener.setConnectionCodeSigningRequirement(teamRequirement)
            listener.delegate = delegate
            listener.setConnectionCodeSigningRequirement(requirement)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            listener.activate()
            captureListener.activate()
            // launchd owns the service name and process singleton. Mach rights
            // are never encoded into a file, and no endpoint cleanup can race.
            withExtendedLifetime((listener, delegate, captureListener, captureDelegate)) { app.run() }
        } catch {
            FileHandle.standardError.write(Data("Tron Native Host could not start its authenticated services.\n".utf8))
            exit(78)
        }
    }
}
NativeHostMain.run()
