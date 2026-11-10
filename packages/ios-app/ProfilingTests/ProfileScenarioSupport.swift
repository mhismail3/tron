import CoreFoundation
import Foundation
@testable import TronMobile
import UIKit
import XCTest

struct ProfileRunConfiguration {
    let scenario: String
    let iterations: Int
    let window: Duration

    static func selected(_ scenario: String, defaultWindow: Duration) throws -> ProfileRunConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TRON_PROFILE_SCENARIO"] == scenario else {
            throw XCTSkip("Profiling scenario \(scenario) runs only through scripts/tron-profile ios.")
        }
        let iterations = Int(environment["TRON_PROFILE_ITERATIONS"] ?? "") ?? 5
        let window = Double(environment["TRON_PROFILE_WINDOW_SECONDS"] ?? "").map { Duration.milliseconds(Int64($0 * 1_000)) }
        guard (1...50).contains(iterations) else {
            throw ProfileScenarioError.invalidConfiguration("TRON_PROFILE_ITERATIONS must be 1...50")
        }
        let resolvedWindow = window ?? defaultWindow
        guard resolvedWindow >= .milliseconds(500), resolvedWindow <= .seconds(600) else {
            throw ProfileScenarioError.invalidConfiguration("TRON_PROFILE_WINDOW_SECONDS must be 0.5...600")
        }
        return ProfileRunConfiguration(scenario: scenario, iterations: iterations, window: resolvedWindow)
    }
}

enum ProfileScenarioError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case timedOut(String)
    case notReady(String)
    case workloadDiverged(String)
    case renderDiverged(String)

    var description: String {
        switch self {
        case .invalidConfiguration(let detail): "invalid profiling configuration: \(detail)"
        case .timedOut(let phase): "profiling phase exceeded its deadline: \(phase)"
        case .notReady(let detail): "scenario did not reach readiness: \(detail)"
        case .workloadDiverged(let detail): "scenario workload was not applied as scripted: \(detail)"
        case .renderDiverged(let detail): "scenario surface did not render the workload in its scripted mode: \(detail)"
        }
    }
}

struct ProfileRenderCheck {
    var counters: [String: Int] = [:]
    var divergence: String?
    var detail = ""
}

@MainActor
protocol ProfileScenarioRun: AnyObject {
    func ready() async throws
    func workload(window: Duration) async throws
    func renderCheck() -> ProfileRenderCheck
    func verify() async throws
    func teardown() async
    var surface: UIView? { get }
}

extension ProfileScenarioRun {
    func renderCheck() -> ProfileRenderCheck { ProfileRenderCheck() }
    func verify() async throws {}
    var surface: UIView? { nil }
}

extension XCTestCase {
    static var profileSetupAttempts: Int { 3 }
    static var profileRenderAttempts: Int { 3 }

    @MainActor
    func profileScenario(
        _ scenario: String,
        defaultWindow: Duration,
        readinessTimeout: Duration = .seconds(180),
        make: @escaping @MainActor (_ window: Duration) async throws -> any ProfileScenarioRun
    ) throws {
        let configuration = try ProfileRunConfiguration.selected(scenario, defaultWindow: defaultWindow)
        ProfileResourceSample.captureMainThread()
        let trace = try ProfileTraceHandshake.requested()
        print("TRON_PROFILE_SCENARIO_START name=\(scenario) transcript_orientation=\(ChatTranscriptOrientation.newestAtOrigin) iterations=\(configuration.iterations) window_ms=\(configuration.window.profileMilliseconds)")
        try trace?.awaitRecording()
        let options = XCTMeasureOptions()
        options.iterationCount = configuration.iterations
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var failure: Error?
        var iteration = 0
        measure(metrics: [ProfileResourceMetric()], options: options) {
            iteration += 1
            startMeasuring()
            defer { stopMeasuring() }
            guard failure == nil else { return }
            var renderAttempt = 0
            while true {
                renderAttempt += 1
                var run: (any ProfileScenarioRun)?
                var rerender = false
                do {
                    let created = try prepareRun(scenario, iteration: iteration, readinessTimeout: readinessTimeout) {
                        try await make(configuration.window)
                    }
                    run = created
                    let windowStart = trace?.windowBound()
                    ProfileMeasuredWindow.shared.begin()
                    try ProfileMainLoop.wait(configuration.window + .seconds(30), phase: "\(scenario) workload") {
                        try await created.workload(window: configuration.window)
                    }
                    ProfileMeasuredWindow.shared.end()
                    let windowEnd = trace?.windowBound()
                    let check = created.renderCheck()
                    let counters = check.counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    print("TRON_PROFILE_RENDER_CHECK name=\(scenario) iteration=\(iteration) attempt=\(renderAttempt) "
                        + "status=\(check.divergence == nil ? "ok" : "diverged") \(counters) \(check.detail)")
                    do {
                        try ProfileMainLoop.wait(.seconds(30), phase: "\(scenario) verification") { try await created.verify() }
                    } catch {
                        attachSurface(of: created, name: "\(scenario)-window-end-failed-\(iteration)")
                        throw error
                    }
                    if let divergence = check.divergence {
                        attachSurface(of: created, name: "\(scenario)-render-diverged-\(iteration)-\(renderAttempt)")
                        guard renderAttempt < Self.profileRenderAttempts else {
                            throw ProfileScenarioError.renderDiverged(
                                "iteration \(iteration) diverged in all \(renderAttempt) attempts; last: \(divergence)"
                            )
                        }
                        print("TRON_PROFILE_RENDER_RETRY name=\(scenario) iteration=\(iteration) attempt=\(renderAttempt) reason=\(divergence)")
                        rerender = true
                    } else {
                        ProfileMeasuredWindow.shared.accept(render: check.counters)
                        if let windowStart, let windowEnd {
                            try trace?.recordWindow(start: windowStart, end: windowEnd, iteration: iteration)
                        }
                        if iteration == 1 { attachSurface(of: created, name: "\(scenario)-window-end") }
                    }
                } catch {
                    failure = error
                }
                if let run {
                    _ = try? ProfileMainLoop.wait(.seconds(30), phase: "\(scenario) teardown") { await run.teardown() }
                }
                if !rerender { break }
            }
            print("TRON_PROFILE_ITERATION name=\(scenario) index=\(iteration) status=\(failure == nil ? "ok" : "failed")")
        }
        try trace?.finishMeasurement()
        if let failure {
            XCTFail("TRON_PROFILE_FAILURE scenario=\(scenario): \(failure)")
        }
    }

    @MainActor
    private func prepareRun(
        _ scenario: String,
        iteration: Int,
        readinessTimeout: Duration,
        make: @escaping @MainActor () async throws -> any ProfileScenarioRun
    ) throws -> any ProfileScenarioRun {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try ProfileMainLoop.wait(readinessTimeout, phase: "\(scenario) setup") {
                    let run = try await make()
                    do { try await run.ready() } catch {
                        self.attachSurface(of: run, name: "\(scenario)-not-ready-\(iteration)-\(attempt)")
                        await run.teardown()
                        throw error
                    }
                    return run
                }
            } catch let error as ProfileScenarioError {
                guard case .notReady = error, attempt < Self.profileSetupAttempts else { throw error }
                print("TRON_PROFILE_SETUP_RETRY name=\(scenario) iteration=\(iteration) attempt=\(attempt) reason=\(error)")
            }
        }
    }
}

extension XCTestCase {
    @MainActor
    func attachSurface(of run: any ProfileScenarioRun, name: String) {
        guard let view = run.surface, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class ProfileTraceHandshake {
    private let directory: URL
    private let recordingTimeout: Duration
    private let stopTimeout: Duration

    private init(directory: URL, recordingTimeout: Duration, stopTimeout: Duration) {
        self.directory = directory
        self.recordingTimeout = recordingTimeout
        self.stopTimeout = stopTimeout
    }

    static func requested() throws -> ProfileTraceHandshake? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRON_PROFILE_TRACE_HANDSHAKE_DIR"], !path.isEmpty else { return nil }
        func seconds(_ name: String) throws -> Duration {
            guard let value = Int64(environment[name] ?? ""), (1...3_600).contains(value) else {
                throw ProfileScenarioError.invalidConfiguration("\(name) must be 1...3600 when tracing")
            }
            return .seconds(value)
        }
        return ProfileTraceHandshake(
            directory: URL(filePath: path, directoryHint: .isDirectory),
            recordingTimeout: try seconds("TRON_PROFILE_TRACE_RECORDING_TIMEOUT_SECONDS"),
            stopTimeout: try seconds("TRON_PROFILE_TRACE_STOP_TIMEOUT_SECONDS")
        )
    }

    func awaitRecording() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try Data("{\"pid\": \(pid)}\n".utf8).write(to: directory.appending(path: "process.json"), options: .atomic)
        print("TRON_PROFILE_TRACE_WAITING pid=\(pid)")
        try wait(for: "recording", timeout: recordingTimeout)
        print("TRON_PROFILE_TRACE_RECORDING")
    }

    func windowBound() -> Date { Date() }

    func recordWindow(start: Date, end: Date, iteration: Int) throws {
        let line = "{\"iteration\": \(iteration), \"start\": \(start.timeIntervalSince1970), \"end\": \(end.timeIntervalSince1970)}\n"
        let url = directory.appending(path: "windows.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    func finishMeasurement() throws {
        try Data().write(to: directory.appending(path: "measured"), options: .atomic)
        print("TRON_PROFILE_TRACE_MEASURED")
        try wait(for: "stopped", timeout: stopTimeout)
    }

    private func wait(for name: String, timeout: Duration) throws {
        let marker = directory.appending(path: name).path
        let abort = directory.appending(path: "abort")
        let deadline = ContinuousClock.now + timeout
        while !FileManager.default.fileExists(atPath: marker) {
            if let reason = try? String(contentsOf: abort, encoding: .utf8) {
                throw ProfileScenarioError.notReady("the profiler aborted tracing: \(reason)")
            }
            guard ContinuousClock.now < deadline else {
                throw ProfileScenarioError.timedOut("trace handshake waiting for \(name)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

@MainActor
enum ProfileMainLoop {
    private final class Box<T> { var result: Result<T, Error>? }

    static func wait<T>(
        _ timeout: Duration,
        phase: String,
        _ body: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let box = Box<T>()
        let task = Task { @MainActor in
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        let deadline = ContinuousClock.now + timeout
        while box.result == nil {
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero {
                task.cancel()
                let grace = ContinuousClock.now + .seconds(5)
                while box.result == nil, ContinuousClock.now < grace {
                    _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
                }
                throw ProfileScenarioError.timedOut(phase)
            }
            _ = CFRunLoopRunInMode(.defaultMode, remaining.profileSeconds, false)
        }
        return try box.result!.get()
    }
}

enum ProfileSink {
    nonisolated(unsafe) static var value: UInt64 = 0

    @inline(never)
    static func consume(_ value: UInt64) { Self.value &+= value }
}

extension Duration {
    var profileSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    var profileMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

func profileSleep(until offset: Duration, from start: ContinuousClock.Instant) async throws {
    try await Task.sleep(until: start + offset, tolerance: .milliseconds(5), clock: .continuous)
}
