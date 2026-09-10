import Darwin
import Foundation

/// This one-shot qualification process is the native-call container. A deadline
/// cannot resume its caller while native work survives: it emits uncertainty and
/// exits this process. This is not the production computer-use Stop contract.
final class QualificationDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var report: Data
    private let timer: DispatchSourceTimer
    private let expire: @Sendable (Data) -> Void

    init(seconds: Double = 45, report: Data,
         expire: @escaping @Sendable (Data) -> Void = { data in
             FileHandle.standardOutput.write(data + Data("\n".utf8))
             _exit(124)
         }) {
        self.report = report
        self.expire = expire
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.schedule(deadline: .now() + seconds)
        timer.resume()
    }

    func update(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if armed { report = data }
    }

    /// Winning this boundary permits exactly one normal terminal report. If the
    /// timer won, its production callback exits while holding this same lock.
    @discardableResult func disarm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return false }
        armed = false
        timer.cancel()
        return true
    }

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return }
        armed = false
        timer.cancel()
        expire(report)
    }
}

/// Only opaque visible window IDs are retained. Fixture setup and AX work must
/// leave other windows ordered identically, with the new fixture behind them.
enum BackgroundWindowOrder {
    static func preserves(_ before: [UInt32], current: [UInt32], fixture: UInt32) -> Bool {
        !before.contains(fixture)
            && current.last == fixture
            && current.filter { $0 != fixture } == before
            && Set(current).count == current.count
    }
}
