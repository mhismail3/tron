import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

struct NativeConsoleSessionState: Sendable {
    let onConsole: Bool
    let loginDone: Bool
    let screenLocked: Bool
    let screensaverActive: Bool?
    let displaysAsleep: Bool
    let lidClosed: Bool?
    let activeDisplayCount: Int
    let topologyGeneration: UUID

    var refusal: NativeCaptureHostError? {
        if !onConsole || !loginDone { return .no_console_session }
        if screenLocked || screensaverActive == true { return .mac_locked }
        if displaysAsleep { return .display_asleep }
        if activeDisplayCount == 0 { return .no_active_display }
        return nil
    }

    var wire: [String: Any] {
        ["onConsole": onConsole, "loginDone": loginDone, "screenLocked": screenLocked,
         "screensaverActive": screensaverActive.map { $0 as Any } ?? NSNull(), "displaysAsleep": displaysAsleep,
         "lidClosed": lidClosed.map { $0 as Any } ?? NSNull(), "activeDisplayCount": activeDisplayCount,
         "topologyGeneration": topologyGeneration.uuidString, "cause": refusal.map { $0.rawValue as Any } ?? NSNull()]
    }
}

final class NativeConsoleSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private let callback: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context else { return }
        let owner = Unmanaged<NativeConsoleSession>.fromOpaque(context).takeUnretainedValue()
        owner.lock.withLock { owner.generation = UUID() }
    }

    init() {
        CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())
    }

    func snapshot() -> NativeConsoleSessionState {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        var displays = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let valid = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success
        let online = valid ? Array(displays.prefix(Int(min(count, UInt32(displays.count))))) : []
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var lidClosed: Bool?
        if root != 0 {
            lidClosed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            IOObjectRelease(root)
        }
        return NativeConsoleSessionState(
            onConsole: (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid()
                && session[kCGSessionOnConsoleKey as String] as? Bool == true,
            loginDone: session[kCGSessionLoginDoneKey as String] as? Bool == true,
            screenLocked: session["CGSSessionScreenIsLocked"] as? Bool == true,
            screensaverActive: session["CGSSessionScreenSaverIsRunning"] as? Bool,
            displaysAsleep: !online.isEmpty && online.allSatisfy { CGDisplayIsAsleep($0) != 0 },
            lidClosed: lidClosed,
            activeDisplayCount: online.filter { CGDisplayIsActive($0) != 0 && (lidClosed != true || CGDisplayIsBuiltin($0) == 0) }.count,
            topologyGeneration: lock.withLock { generation })
    }
}

final class NativeComputerActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID

    init() throws {
        var assertion = IOPMAssertionID(kIOPMNullAssertionID)
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), "Tron active computer turn" as CFString,
                                         &assertion) == kIOReturnSuccess else { throw NativeCaptureHostError.unavailable }
        self.assertion = assertion
    }

    func close() {
        let value = lock.withLock {
            let value = assertion
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
            return value
        }
        if value != kIOPMNullAssertionID { IOPMAssertionRelease(value) }
    }

    deinit { close() }
}
