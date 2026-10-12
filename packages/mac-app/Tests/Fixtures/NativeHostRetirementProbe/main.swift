import Foundation
import TronNativeCaptureHost

/// A launchd-demand-launched stand-in for the native helper's wrapper service.
/// It serves only retirement, through the production retirement owner, and
/// really exits the process when that owner terminates it.
final class ProbeService: NSObject, NativeHostPermissionService {
    private let retirement = NativeHostServiceRetirement(captures: NativeCaptureSlot(), retireAutomation: {}) { exit(0) }
    func probePermissions(withReply reply: @escaping @Sendable ([String: String]) -> Void) { reply([:]) }
    func prepareForServiceRetirement(withReply reply: @escaping @Sendable (Bool) -> Void) {
        retirement.prepare(withReply: reply)
    }
    func requestPermission(_ permission: String, requestID: String,
                           withReply reply: @escaping @Sendable (String, String) -> Void) {
        reply(requestID, NativeHostPermissionStatus.probeUnavailable.rawValue)
    }
}

final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    let service = ProbeService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: NativeHostPermissionService.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

guard CommandLine.arguments.count == 2 else { exit(64) }
let delegate = ProbeDelegate()
let listener = NSXPCListener(machServiceName: CommandLine.arguments[1])
listener.delegate = delegate
listener.activate()
withExtendedLifetime((listener, delegate)) { dispatchMain() }
