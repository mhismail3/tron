import CoreFoundation
import Foundation
import UIKit
import XCTest

/// Selection and timing handed to the hosted test process by
/// `scripts/tron-profile ios` through `TEST_RUNNER_`-prefixed xcodebuild
/// environment (xcodebuild strips the prefix for the test process). A scenario
/// test skips unless it is the selected scenario, so ordinary unit runs never
/// execute profiling workloads.
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

    var description: String {
        switch self {
        case .invalidConfiguration(let detail): "invalid profiling configuration: \(detail)"
        case .timedOut(let phase): "profiling phase exceeded its deadline: \(phase)"
        case .notReady(let detail): "scenario did not reach readiness: \(detail)"
        case .workloadDiverged(let detail): "scenario workload was not applied as scripted: \(detail)"
        }
    }
}

/// One scenario instance: built and made ready outside the measured window,
/// driven for exactly the window inside it, and torn down afterwards.
@MainActor
protocol ProfileScenarioRun: AnyObject {
    /// Waits (bounded) until the mounted surface shows the fixture state.
    func ready() async throws
    /// Applies the scripted workload for exactly `window`.
    func workload(window: Duration) async throws
    /// After the window, proves the workload was applied as scripted.
    func verify() async throws
    func teardown() async
    /// The mounted surface, captured once per run as evidence of what the
    /// window measured.
    var surface: UIView? { get }
}

extension ProfileScenarioRun {
    func verify() async throws {}
    var surface: UIView? { nil }
}

extension XCTestCase {
    static var profileSetupAttempts: Int { 3 }

    /// Runs `iterations` fresh scenario instances under `ProfileResourceMetric`.
    /// Setup and readiness happen before `startMeasuring`, teardown after
    /// `stopMeasuring`, so each sample covers only the scripted window.
    @MainActor
    func profileScenario(
        _ scenario: String,
        defaultWindow: Duration,
        readinessTimeout: Duration = .seconds(180),
        make: @escaping @MainActor (_ window: Duration) async throws -> any ProfileScenarioRun
    ) throws {
        let configuration = try ProfileRunConfiguration.selected(scenario, defaultWindow: defaultWindow)
        ProfileResourceSample.captureMainThread()
        print("TRON_PROFILE_SCENARIO_START name=\(scenario) iterations=\(configuration.iterations) window_ms=\(configuration.window.profileMilliseconds)")
        let options = XCTMeasureOptions()
        options.iterationCount = configuration.iterations
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var failure: Error?
        var iteration = 0
        measure(metrics: [ProfileResourceMetric()], options: options) {
            iteration += 1
            // XCTest requires every invocation to start and stop measuring;
            // after a failure, the remaining invocations measure nothing and
            // the test fails with the first error.
            guard failure == nil else {
                startMeasuring()
                stopMeasuring()
                return
            }
            var run: (any ProfileScenarioRun)?
            var measuring = false
            do {
                // Setup is outside the window, so a scenario that did not reach
                // readiness (for example a chat opening that did not settle on a
                // loaded host) is rebuilt from scratch a bounded number of times.
                // Retries are printed; the profiler reports them as warnings.
                var attempt = 0
                var prepared: (any ProfileScenarioRun)?
                while prepared == nil {
                    attempt += 1
                    do {
                        prepared = try ProfileMainLoop.wait(readinessTimeout, phase: "\(scenario) setup") {
                            let run = try await make(configuration.window)
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
                let created = prepared!
                run = created
                startMeasuring()
                measuring = true
                try ProfileMainLoop.wait(configuration.window + .seconds(30), phase: "\(scenario) workload") {
                    try await created.workload(window: configuration.window)
                }
                stopMeasuring()
                measuring = false
                do {
                    try ProfileMainLoop.wait(.seconds(30), phase: "\(scenario) verification") { try await created.verify() }
                } catch {
                    attachSurface(of: created, name: "\(scenario)-window-end-failed-\(iteration)")
                    throw error
                }
                if iteration == 1 { attachSurface(of: created, name: "\(scenario)-window-end") }
            } catch {
                failure = error
                if !measuring { startMeasuring() }
                stopMeasuring()
            }
            if let run {
                _ = try? ProfileMainLoop.wait(.seconds(30), phase: "\(scenario) teardown") { await run.teardown() }
            }
            print("TRON_PROFILE_ITERATION name=\(scenario) index=\(iteration) status=\(failure == nil ? "ok" : "failed")")
        }
        if let failure {
            XCTFail("TRON_PROFILE_FAILURE scenario=\(scenario): \(failure)")
        }
    }
}

extension XCTestCase {
    /// Evidence of what the window measured: the mounted surface as drawn.
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

/// Drives main-actor async work from XCTest's synchronous measure block. The
/// main run loop sleeps until the work finishes (the task stops it), so the
/// wait itself adds no polling wakeups to the measured window.
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
                // Give cancellation a bounded chance to retire the work before
                // reporting, so a timed-out scenario does not leak into teardown.
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

/// Keeps synthetic work observable to the optimizer.
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

/// Sleeps until an absolute offset from a window start, so a scripted cadence
/// does not drift with the work each step does.
func profileSleep(until offset: Duration, from start: ContinuousClock.Instant) async throws {
    try await Task.sleep(until: start + offset, clock: .continuous)
}
