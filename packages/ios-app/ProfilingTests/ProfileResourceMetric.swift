import Darwin
import Foundation
import Synchronization
import XCTest

/// In-process resource counters for `scripts/tron-profile ios`.
///
/// Every value below is the delta over the one window the iteration accepted
/// (`ProfileMeasuredWindow`), which XCTest's `stopMeasuring()` hands to this
/// metric through `didStopMeasuring`. The profiler reads the values back
/// from the xcresult by their `com.tron.profile.` identifiers; the suffix is
/// the report metric id. A counter the kernel does not provide in this process
/// is omitted rather than reported as zero, so a report never contains a
/// fabricated measurement.
final class ProfileResourceMetric: NSObject, XCTMetric {
    static let identifierPrefix = "com.tron.profile."

    private var window: ProfileMeasuredWindow.Sample?

    func copy(with zone: NSZone? = nil) -> Any { ProfileResourceMetric() }

    func willBeginMeasuring() {
        ProfileMeasuredWindow.shared.reset()
    }

    func didStopMeasuring() {
        window = ProfileMeasuredWindow.shared.takeAccepted()
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp,
        to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        guard let window else { return [] }
        let start = window.start, end = window.end
        let scenarioStart = window.scenarioStart, scenarioEnd = window.scenarioEnd
        var values: [XCTPerformanceMeasurement] = [
            Self.measurement("time.wall", "Wall time", Double(end.wallNanoseconds &- start.wallNanoseconds), "ns"),
            Self.measurement("cpu.time", "Process CPU time", Double(end.processCPUNanoseconds &- start.processCPUNanoseconds), "ns"),
        ]
        if let before = start.mainThreadCPUNanoseconds, let after = end.mainThreadCPUNanoseconds {
            values.append(Self.measurement("cpu.main_thread_time", "Main-thread CPU time", Double(after &- before), "ns"))
        }
        if let before = start.usage, let after = end.usage {
            // Zero lifetime instructions means this process has no per-task
            // performance counters (a kernel or virtualization limit), not
            // that it retired none.
            if after.ri_instructions > 0 {
                values.append(Self.measurement("cpu.instructions", "Instructions retired", Double(after.ri_instructions &- before.ri_instructions), "instructions"))
                values.append(Self.measurement("cpu.cycles", "Cycles", Double(after.ri_cycles &- before.ri_cycles), "cycles"))
            }
            if after.ri_energy_nj > 0 {
                values.append(Self.measurement("energy.cpu", "CPU energy", Double(after.ri_energy_nj &- before.ri_energy_nj), "nJ"))
            }
            values.append(Self.measurement("disk.bytes_written", "Disk bytes written", Double(after.ri_diskio_byteswritten &- before.ri_diskio_byteswritten), "B"))
            values.append(Self.measurement("disk.bytes_read", "Disk bytes read", Double(after.ri_diskio_bytesread &- before.ri_diskio_bytesread), "B"))
            values.append(Self.measurement("disk.logical_writes", "Logical writes", Double(after.ri_logical_writes &- before.ri_logical_writes), "B"))
            if ProfileResourceSample.canResetIntervalFootprint {
                values.append(Self.measurement("memory.peak_footprint", "Peak memory footprint", Double(after.ri_interval_max_phys_footprint), "B"))
            }
        }
        if let before = start.power, let after = end.power {
            values.append(Self.measurement("wakeups.interrupt", "Interrupt wakeups", Double(after.cpu_energy.task_interrupt_wakeups &- before.cpu_energy.task_interrupt_wakeups), "wakeups"))
            values.append(Self.measurement("wakeups.idle", "Platform-idle wakeups", Double(after.cpu_energy.task_platform_idle_wakeups &- before.cpu_energy.task_platform_idle_wakeups), "wakeups"))
        }
        for name in Set(scenarioStart.keys).union(scenarioEnd.keys).sorted() {
            let delta = (scenarioEnd[name] ?? 0) - (scenarioStart[name] ?? 0)
            values.append(Self.measurement("scenario.\(ProfileScenarioLedger.metricID(name))", "Scenario \(name)", Double(delta), ProfileScenarioLedger.unit(for: name)))
        }
        for (name, value) in window.render.sorted(by: { $0.key < $1.key }) {
            let id = "render.\(ProfileScenarioLedger.metricID(name))"
            values.append(Self.measurement("scenario.\(id)", "Scenario \(id)", Double(value), "count"))
        }
        return values
    }

    private static func measurement(_ id: String, _ name: String, _ value: Double, _ unit: String) -> XCTPerformanceMeasurement {
        XCTPerformanceMeasurement(
            identifier: identifierPrefix + id,
            displayName: name,
            doubleValue: value,
            unitSymbol: unit,
            polarity: .prefersSmaller
        )
    }
}

/// The measured window of the current iteration. The harness brackets each
/// attempted window with `begin`/`end` and accepts it only after its render
/// check passed, so a discarded window never reaches the metric.
final class ProfileMeasuredWindow: Sendable {
    struct Sample {
        var start: ProfileResourceSample
        var end: ProfileResourceSample
        var scenarioStart: [String: Int]
        var scenarioEnd: [String: Int]
        var render: [String: Int]
    }

    private struct State {
        var start: ProfileResourceSample?
        var scenarioStart: [String: Int] = [:]
        var ended: Sample?
        var accepted: Sample?
    }

    static let shared = ProfileMeasuredWindow()

    private let state = Mutex(State())

    func reset() { state.withLock { $0 = State() } }

    func begin() {
        let scenarioStart = ProfileScenarioLedger.shared.snapshot()
        ProfileResourceSample.resetIntervalFootprint()
        let start = ProfileResourceSample.capture()
        state.withLock { $0 = State(start: start, scenarioStart: scenarioStart) }
    }

    func end() {
        let end = ProfileResourceSample.capture()
        let scenarioEnd = ProfileScenarioLedger.shared.snapshot()
        state.withLock { current in
            guard let start = current.start else { return }
            current.ended = Sample(start: start, end: end, scenarioStart: current.scenarioStart,
                                   scenarioEnd: scenarioEnd, render: [:])
        }
    }

    func accept(render: [String: Int]) {
        state.withLock { current in
            current.accepted = current.ended.map { var sample = $0; sample.render = render; return sample }
        }
    }

    func takeAccepted() -> Sample? {
        state.withLock { current in
            defer { current = State() }
            return current.accepted
        }
    }
}

/// One reading of the process counters. Every source is read directly from the
/// kernel for this process; the simulator app is an ordinary host process, so
/// these are host-CPU values, not device battery measurements.
struct ProfileResourceSample {
    let wallNanoseconds: UInt64
    let processCPUNanoseconds: UInt64
    let mainThreadCPUNanoseconds: UInt64?
    let usage: rusage_info_v6?
    let power: task_power_info_v2?

    static func capture() -> ProfileResourceSample {
        ProfileResourceSample(
            wallNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
            processCPUNanoseconds: clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID),
            mainThreadCPUNanoseconds: mainThreadCPU(),
            usage: resourceUsage(),
            power: powerInfo()
        )
    }

    // libproc is not in the iOS SDK. Resolve the host's C entry points at run
    // time with their C calling convention instead of declaring Swift symbols.
    private typealias ProcPIDRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32
    private typealias ProcResetFootprintInterval = @convention(c) (Int32) -> Int32

    private static let procPIDRusage: ProcPIDRusage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage")
        .map { unsafeBitCast($0, to: ProcPIDRusage.self) }
    private static let procResetFootprintInterval: ProcResetFootprintInterval? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_reset_footprint_interval")
        .map { unsafeBitCast($0, to: ProcResetFootprintInterval.self) }

    static var canResetIntervalFootprint: Bool { procResetFootprintInterval != nil }

    static func resetIntervalFootprint() {
        _ = procResetFootprintInterval?(getpid())
    }

    private static func resourceUsage() -> rusage_info_v6? {
        guard let procPIDRusage else { return nil }
        var value = rusage_info_v6()
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            procPIDRusage(getpid(), RUSAGE_INFO_V6, buffer.baseAddress!)
        }
        return status == 0 ? value : nil
    }

    private static func powerInfo() -> task_power_info_v2? {
        var value = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? value : nil
    }

    /// XCTest may call metric hooks off the main thread, so the main thread's
    /// port is captured on it once, before any measurement.
    nonisolated(unsafe) private static var mainThreadPort: mach_port_t?

    @MainActor
    static func captureMainThread() {
        mainThreadPort = pthread_mach_thread_np(pthread_self())
    }

    private static func mainThreadCPU() -> UInt64? {
        guard let mainThreadPort else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainThreadPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let microseconds = (UInt64(info.user_time.seconds) + UInt64(info.system_time.seconds)) * 1_000_000
            + UInt64(info.user_time.microseconds) + UInt64(info.system_time.microseconds)
        return microseconds * 1_000
    }
}

/// Workload counters a scenario records while it runs (frames and bytes its
/// scripted transport delivered, RPCs it answered, resynchronizations it
/// observed). The metric reports their deltas over the measured window so a
/// report proves the workload was applied, not only that time passed.
final class ProfileScenarioLedger: Sendable {
    static let shared = ProfileScenarioLedger()

    private let counters = Mutex<[String: Int]>([:])

    func add(_ name: String, _ amount: Int = 1) {
        counters.withLock { $0[name, default: 0] += amount }
    }

    func snapshot() -> [String: Int] { counters.withLock { $0 } }

    func reset() { counters.withLock { $0.removeAll() } }

    /// Report metric ids are lowercase: `session.toolProgress` becomes
    /// `session.tool_progress`.
    static func metricID(_ name: String) -> String {
        name.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
        }
    }

    static func unit(for name: String) -> String {
        name.split(separator: ".").contains { $0 == "bytes" || $0.hasSuffix("_bytes") } ? "B" : "count"
    }
}
