import Foundation
import XCTest

/// Measurement-path self-test for `scripts/tron-profile ios --self-test`.
///
/// `control` runs a fixed synthetic workload; each variant adds one known cost
/// on top of it. The profiler fails unless every variant regresses its target
/// metric beyond the report's noise bound, so a broken counter, a lost
/// xcresult value, or an extraction bug is caught before anyone trusts a
/// product scenario. These workloads exist only in the hosted test bundle.
@MainActor
final class ProfileControlScenarioTests: XCTestCase {
    func testControl() throws {
        try profileScenario("control", defaultWindow: .seconds(2)) { _ in ProfileControlRun(extra: nil) }
    }

    func testControlExtraCPU() throws {
        try profileScenario("control-cpu", defaultWindow: .seconds(2)) { _ in ProfileControlRun(extra: .cpu) }
    }

    func testControlExtraDisk() throws {
        try profileScenario("control-disk", defaultWindow: .seconds(2)) { _ in ProfileControlRun(extra: .disk) }
    }

    func testControlExtraWakeups() throws {
        try profileScenario("control-wakeups", defaultWindow: .seconds(2)) { _ in ProfileControlRun(extra: .wakeups) }
    }
}

@MainActor
private final class ProfileControlRun: ProfileScenarioRun {
    enum Extra { case cpu, disk, wakeups }

    /// 10 Hz ticks of fixed arithmetic: a small, steady main-thread workload.
    static let tick = Duration.milliseconds(100)
    static let workPerTick = 400_000
    /// The disk variant writes and syncs this much per tick.
    static let bytesPerTick = 256 * 1_024
    /// The wakeup variant adds a 200 Hz main-run-loop timer.
    static let extraTimerInterval: TimeInterval = 0.005

    private let extra: Extra?
    private let directory: URL
    private var timer: Timer?
    private var expectedTicks = 0

    init(extra: Extra?) {
        self.extra = extra
        directory = FileManager.default.temporaryDirectory.appending(path: "tron-profile-control-\(UUID().uuidString)", directoryHint: .isDirectory)
        ProfileScenarioLedger.shared.reset()
        for name in ["control.ticks", "control.extra_work", "control.extra_bytes", "control.extra_timer_fires"] {
            ProfileScenarioLedger.shared.add(name, 0)
        }
    }

    func ready() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func workload(window: Duration) async throws {
        let start = ContinuousClock.now
        if extra == .wakeups {
            let timer = Timer(timeInterval: Self.extraTimerInterval, repeats: true) { _ in
                ProfileScenarioLedger.shared.add("control.extra_timer_fires")
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        defer { timer?.invalidate(); timer = nil }
        let ticks = Int(window.profileMilliseconds / Self.tick.profileMilliseconds)
        let payload = Data(repeating: 0x5A, count: Self.bytesPerTick)
        for index in 0..<ticks {
            try await profileSleep(until: Self.tick * index, from: start)
            ProfileSink.consume(Self.arithmetic(seed: UInt64(index), rounds: Self.workPerTick))
            ProfileScenarioLedger.shared.add("control.ticks")
            switch extra {
            case .cpu:
                ProfileSink.consume(Self.controlExtraCPUWorkload(seed: UInt64(index) &+ 7, rounds: Self.workPerTick))
                ProfileScenarioLedger.shared.add("control.extra_work")
            case .disk:
                let url = directory.appending(path: "tick-\(index)")
                let handle = try FileHandle(forWritingTo: {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    return url
                }())
                try handle.write(contentsOf: payload)
                try handle.synchronize()
                try handle.close()
                ProfileScenarioLedger.shared.add("control.extra_bytes", payload.count)
            case .wakeups, nil:
                break
            }
        }
        try await profileSleep(until: window, from: start)
        expectedTicks = ticks
    }

    func verify() async throws {
        let applied = ProfileScenarioLedger.shared.snapshot()["control.ticks"] ?? 0
        guard applied == expectedTicks else {
            throw ProfileScenarioError.workloadDiverged("control applied \(applied) of \(expectedTicks) ticks")
        }
    }

    func teardown() async {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The CPU variant's known cost as its own frame: `--self-test --trace
    /// time-profiler` fails unless attribution ranks this symbol among the top
    /// self-time symbols (CONTROL_WORKLOAD_SYMBOL in scripts/tron-profile-ios).
    /// Its loop differs from `arithmetic` on purpose: an identical body would
    /// be merged or tail-called by the optimizer, and this frame would vanish.
    @inline(never)
    static func controlExtraCPUWorkload(seed: UInt64, rounds: Int) -> UInt64 {
        var state = seed | 1
        for _ in 0..<rounds {
            state ^= state << 7
            state ^= state >> 9
            state ^= state << 8
        }
        return state
    }

    /// Fixed xorshift rounds; the result feeds `ProfileSink` so -O keeps it.
    private static func arithmetic(seed: UInt64, rounds: Int) -> UInt64 {
        var state = seed | 1
        for _ in 0..<rounds {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
        }
        return state
    }
}
