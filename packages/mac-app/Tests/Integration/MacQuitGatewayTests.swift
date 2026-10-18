import Darwin
import Foundation
import Testing
@testable import TronMac

/// The signed built Mac owner talks to its signed bundled Gateway, supervised by
/// a disposable launchd job with the production SuccessfulExit=false policy.
/// Nothing addresses the installed service, an existing Gateway, or live stores.
@Suite("Mac Quit with a real supervised Gateway", .serialized)
struct MacQuitGatewayTests {
    enum Scenario: String, CaseIterable {
        case normal, blockedExit, missingReceipt, staleReceipt, malformedReceipt, foreignPID, receiptWriteFailure, acceptedWork
        var blocksExit: Bool { self != .normal && self != .acceptedWork }
    }

    @Test("the fixture supervisor really relaunches an unsuccessful exit")
    func restartControl() async throws {
        let fixture = try QuitGatewayFixture(scenario: .normal)
        defer { fixture.cleanup() }
        try await fixture.waitUntilServing()
        _ = try await GatewayRestartClient.restart(host: "127.0.0.1", port: fixture.port(), token: fixture.token())
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while fixture.launchCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(fixture.launchCount == 2, "negative control: launchd must actually enforce SuccessfulExit=false")
    }

    @Test("recovery refuses a changed process identity before bootout")
    @MainActor
    func changedIdentity() async throws {
        let fixture = try QuitGatewayFixture(scenario: .normal)
        defer { fixture.cleanup() }
        try await fixture.waitUntilServing()
        let runtime = try #require(try await LaunchAgentRuntimeReader.read(label: fixture.label))
        let pid = try #require(runtime.pid)
        let command = try #require(runtime.processCommand)
        do {
            try await MacQuitCoordinator.retireCompletedGateway(
                label: fixture.label, pid: pid, command: command, start: "different-process-start"
            )
            Issue.record("an unproven process identity must never authorize bootout")
        } catch { #expect(error as? MacQuitCoordinator.Failure == .runtimeReplaced) }
        #expect(fixture.isRunning)
        #expect(try await LaunchAgentRuntimeReader.read(label: fixture.label)?.pid == pid)
    }

    @Test("infinite launchd termination policy refuses removal before touching the job")
    @MainActor
    func unsupportedPolicy() async throws {
        let fixture = try QuitGatewayFixture(scenario: .normal, exitTimeoutOverride: 0)
        defer { fixture.cleanup() }
        try await fixture.waitUntilServing()
        let runtime = try #require(try await LaunchAgentRuntimeReader.read(label: fixture.label))
        let pid = try #require(runtime.pid)
        let command = try #require(runtime.processCommand)
        let start = try #require(await ServerProcessProbe.processStartIdentity(pid: pid))
        do {
            try await MacQuitCoordinator.retireCompletedGateway(label: fixture.label, pid: pid, command: command, start: start)
            Issue.record("unknown/infinite/unreasonable supervisor policy must not authorize removal")
        } catch { #expect(error as? MacQuitCoordinator.Failure == .retirementPolicy) }
        #expect(try await LaunchAgentRuntimeReader.read(label: fixture.label)?.pid == pid)
        #expect(fixture.isRunning)
        #expect(!fixture.logContains(event: "gateway.stopping"), "refusal must not send a shutdown signal")
    }

    @Test("intentional stop preserves work and has a bounded post-shutdown result", arguments: Scenario.allCases)
    @MainActor
    func intentionalStop(scenario: Scenario) async throws {
        let fixture = try QuitGatewayFixture(scenario: scenario)
        defer { fixture.cleanup() }
        try await fixture.waitUntilServing()
        if scenario == .acceptedWork { try await fixture.startAcceptedWork() }
        let token = try fixture.token()
        let port = try fixture.port()
        var nativeRetired = false
        var stopRequests = 0
        var stopCommandID: String?
        var recoveryRequests = 0
        let coordinator = MacQuitCoordinator(
            readRuntime: { try await LaunchAgentRuntimeReader.read(label: fixture.label) },
            processStartIdentity: { await ServerProcessProbe.processStartIdentity(pid: $0) },
            runtimeOwnershipHealthy: {
                guard let runtime = try? await LaunchAgentRuntimeReader.read(label: fixture.label) else { return false }
                return runtime.pid == Int(fixture.pid)
                    && runtime.processCommand?.contains(fixture.root.appendingPathComponent("start.mjs").path) == true
            },
            serviceEnabled: { fixture.jobEnabled },
            shutdownCompleted: { pid, drainID in
                // Read the real receipt. Corruption controls happen in the
                // exit preload, before this process can observe completion.
                await MacQuitCoordinator.hasCompletedShutdown(pid: pid, drainID: drainID, receiptURL: fixture.receipt)
            },
            readDrain: { try await GatewayStopClient.drain(host: "127.0.0.1", port: port, token: token) },
            stopGateway: { command in
                await MainActor.run { stopRequests += 1; stopCommandID = command }
                return try await GatewayStopClient.stop(host: "127.0.0.1", port: port, token: token, commandID: command)
            },
            retireCompletedGateway: { pid, command, start in
                await MainActor.run { recoveryRequests += 1 }
                try await MacQuitCoordinator.retireCompletedGateway(
                    label: fixture.label, pid: pid, command: command, start: start
                )
                fixture.didBootout()
            },
            retireNativeHost: { await MainActor.run { nativeRetired = true } }
        )
        var result: Result<Void, Error>?
        let quit = Task { @MainActor in
            do { try await coordinator.quit(); result = .success(()) }
            catch { result = .failure(error) }
        }
        if scenario == .blockedExit {
            // UI/runner cancellation cannot abandon an accepted stop or its
            // launchd retirement. Duplicate callers still join this same owner.
            try await Task.sleep(for: .seconds(2))
            quit.cancel()
        }
        if scenario == .acceptedWork {
            // Longer than BOTH the exit grace and launchd's shipped 20s signal
            // budget: a real held model request must never authorize bootout.
            try await Task.sleep(for: .seconds(22))
            #expect(result == nil, "a reachable accepted-work drain must not have a wall-clock cutoff")
            #expect(fixture.isRunning)
            #expect(!nativeRetired)
            #expect(!FileManager.default.fileExists(atPath: fixture.receipt.path))
            let drain = try await GatewayStopClient.drain(host: "127.0.0.1", port: port, token: token)
            #expect(drain.phase == "waiting")
            try Data().write(to: fixture.root.appendingPathComponent("release-model"))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while result == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let observed = result
        let remainedAlive = fixture.isRunning
        let observedNativeRetirement = nativeRetired
        let shutdownRecorded = fixture.logContains(event: "gateway.stopped")
        if observed == nil { fixture.stop() }
        await quit.value
        // Successful duplicate callers join the same Quit, not another outcome.
        // Read immediately: the owner must flush before permitting app termination.
        if case .success = observed { try await coordinator.quit() }
        let commandID = try #require(stopCommandID)
        let macLog = TronPaths.tronHome.appendingPathComponent("logs/mac.jsonl")
        let records = ((try? String(contentsOf: macLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }.filter { $0["event"] as? String == "app.quit.gateway-exit" && $0["commandId"] as? String == commandID }
        #expect(records.count == 1, "each coordinated stop must write exactly one final outcome")
        if let record = records.first {
            let expected = scenario == .blockedExit ? "recovered" : (scenario.blocksExit ? "blocked" : "clean")
            #expect(record["outcome"] as? String == expected)
            #expect(record["pid"] as? Int == Int(fixture.pid))
            let elapsed = try #require(record["elapsedMs"] as? Int)
            #expect(elapsed >= 0)
            if scenario == .blockedExit {
                #expect(elapsed >= 25_000, "recovery must observe launchd's shipped 20s termination window after the exit grace")
            }
        }
        #expect(shutdownRecorded, "the real Gateway did not complete its intentional shutdown")
        #expect(observed != nil, "Mac Quit stayed pending after the real Gateway completed shutdown")
        #expect(recoveryRequests == (scenario == .blockedExit ? 1 : 0), "only proven completed exit stalls authorize bootout")
        if scenario.blocksExit && scenario != .blockedExit {
            #expect(remainedAlive, "uncertain shutdown must leave the exact process untouched")
            #expect(!observedNativeRetirement, "uncertainty must leave wrapper/native-host retirement incomplete")
            if case .failure(let error) = observed {
                #expect(error as? MacQuitCoordinator.Failure == .observation)
            } else { Issue.record("blocked exit must report a bounded truthful failure") }
            #expect(!fixture.logContains(event: "gateway.exit-stalled"))
            if scenario == .receiptWriteFailure { #expect(fixture.logContains(event: "gateway.stop-completion.failed")) }
        } else {
            #expect(!remainedAlive)
            #expect(observedNativeRetirement)
            if case .failure(let error) = observed { Issue.record("completed stop failed: \(error)") }
            let runtime = try await LaunchAgentRuntimeReader.read(label: fixture.label)
            #expect(runtime?.pid == nil)
            #expect((runtime == nil) == (scenario == .blockedExit), "normal exit 0 must leave its job registered")
        }
        // Observe the actual supervisor after its restart throttle. A signal
        // escalation or unsuccessful normal exit would start a second Gateway.
        try await Task.sleep(for: .seconds(2))
        #expect(fixture.launchCount == 1, "intentional stop must not trigger launchd relaunch")
        if scenario == .blockedExit {
            #expect(!fixture.isRunning, "completed intentional stop must recover without manual bootout")
            #expect(stopRequests == 1)
            #expect(!fixture.logContains(event: "gateway.exit-stalled"), "exit 0 must not install a SIGKILL watcher")
        }
        if scenario.blocksExit && scenario != .blockedExit {
            // Let Node's held exit finish with 0; leave the supervisor job
            // registered so Retry exercises the real stopped-but-enabled case.
            try Data().write(to: fixture.root.appendingPathComponent("release-exit"))
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while fixture.isRunning && ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(!fixture.isRunning)
            #expect(fixture.launchCount == 1)
            try await coordinator.quit()
            #expect(nativeRetired, "safe retry after exact fixture retirement must finish")
            #expect(stopRequests == 1)
        }
    }
}

private final class QuitGatewayFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let log: URL
    let receipt: URL
    let label = "com.tron.test.quit.\(UUID().uuidString.lowercased())"
    private var bootstrapped = false
    var jobEnabled: Bool { bootstrapped }
    private var capturedPID: Int32 = 0
    var pid: Int32 { capturedPID }
    var isRunning: Bool { capturedPID > 0 && kill(capturedPID, 0) == 0 }
    var launchCount: Int { ((try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? "").split(separator: "\n").count }
    private var service: String { "gui/\(getuid())/\(label)" }

    init(scenario: MacQuitGatewayTests.Scenario, exitTimeoutOverride: Int? = nil) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("tron-mac-quit-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("tron", isDirectory: true)
        log = home.appendingPathComponent("logs/gateway.jsonl")
        receipt = home.appendingPathComponent("gateway/stop-completed.json")
        do {
            for path in ["", "home", "tmp", "agent", "project", "payload/app/dist"] {
                try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let resources = try #require(Bundle.main.resourceURL)
            let gateway = resources.appendingPathComponent("Gateway/app", isDirectory: true)
            #if arch(arm64)
            let node = resources.appendingPathComponent("Gateway/runtime/bin-arm64/node")
            #else
            let node = resources.appendingPathComponent("Gateway/runtime/bin-x64/node")
            #endif
            let script = root.appendingPathComponent("start.mjs")
            let source = #"""
            import {createServer as netServer} from 'node:net';
            import {createServer as httpServer} from 'node:http';
            import {appendFileSync, writeFileSync, readFileSync, existsSync, mkdirSync, rmSync} from 'node:fs';
            const root = process.env.QUIT_ROOT;
            const receipt = root + '/tron/gateway/stop-completed.json';
            appendFileSync(root + '/launches', process.pid + '\n');
            const server = netServer();
            await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
            process.env.TRON_GATEWAY_PORT = String(server.address().port);
            writeFileSync(root + '/port', process.env.TRON_GATEWAY_PORT);
            await new Promise(resolve => server.close(resolve));
            if (process.env.QUIT_SCENARIO === 'acceptedWork') {
              const model = httpServer((request, response) => {
                request.resume();
                request.on('end', () => {
                  writeFileSync(root + '/model-started', '');
                  const timer = setInterval(() => {
                    if (!existsSync(root + '/release-model')) return;
                    clearInterval(timer);
                    response.writeHead(200, {'content-type': 'text/event-stream'});
                    const chunk = (delta, finish_reason = null) => 'data: ' + JSON.stringify({id:'fixture', object:'chat.completion.chunk', model:'held', choices:[{index:0, delta, finish_reason}]}) + '\n\n';
                    response.end(chunk({role:'assistant', content:'Accepted work completed.'}) + chunk({}, 'stop') + 'data: [DONE]\n\n');
                  }, 50);
                });
              });
              await new Promise(resolve => model.listen(0, '127.0.0.1', resolve));
              writeFileSync(root + '/agent/settings.json', JSON.stringify({defaultProvider:'quit-fixture', defaultModel:'held'}));
              writeFileSync(root + '/agent/models.json', JSON.stringify({providers:{'quit-fixture':{
                baseUrl:'http://127.0.0.1:' + model.address().port + '/v1', api:'openai-completions', apiKey:'synthetic-fixture-key',
                models:[{id:'held', name:'Held fixture', reasoning:false, input:['text'], contextWindow:100000, maxTokens:1024}]
              }}}));
            }
            if (process.env.QUIT_SCENARIO === 'receiptWriteFailure') {
              mkdirSync(receipt, {recursive:true, mode:0o700});
            }
            // Model signal-insensitive teardown after the real completion
            // receipt, retaining the Gateway's installed SIGTERM handler. This
            // deterministic stall is not a reproduction of #1120's native cause.
            const exit = process.exit.bind(process);
            if (process.env.QUIT_HANG === '1') process.exit = code => {
              if (process.env.QUIT_SCENARIO === 'missingReceipt') rmSync(receipt, {force:true});
              if (process.env.QUIT_SCENARIO === 'staleReceipt') writeFileSync(receipt, JSON.stringify({version:1,pid:process.pid,drainId:'unrelated-drain'}));
              if (process.env.QUIT_SCENARIO === 'malformedReceipt') writeFileSync(receipt, '{malformed');
              if (process.env.QUIT_SCENARIO === 'foreignPID') {
                const value = JSON.parse(readFileSync(receipt, 'utf8'));
                writeFileSync(receipt, JSON.stringify({...value, pid:1}));
              }
              // Log loss must not change the authoritative completion handoff.
              writeFileSync(root + '/shutdown-log.jsonl', readFileSync(root + '/tron/logs/gateway.jsonl'));
              rmSync(root + '/tron/logs/gateway.jsonl', {force:true});
              while (!existsSync(root + '/release-exit')) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,100);
              exit(code);
            };
            await import(process.env.QUIT_GATEWAY_ENTRY);
            """#
            try Data(source.utf8).write(to: script)
            try Data().write(to: root.appendingPathComponent("payload/app/dist/index.js"))
            let environment = [
                "PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
                "TMPDIR": root.appendingPathComponent("tmp").path,
                "TRON_DATA_DIR": home.path, "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path,
                "PI_SUBAGENTS_TEMP_ROOT": home.appendingPathComponent("internal/subagents").path,
                "TRON_GATEWAY_HOST": "127.0.0.1", "TRON_GATEWAY_SUPERVISED": "1",
                "TRON_GATEWAY_PAYLOAD_ROOT": root.appendingPathComponent("payload").path,
                "QUIT_ROOT": root.path, "QUIT_SCENARIO": scenario.rawValue,
                "QUIT_GATEWAY_ENTRY": gateway.appendingPathComponent("dist/index.js").absoluteString,
                "QUIT_HANG": scenario.blocksExit ? "1" : "0",
            ]
            let shippedPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.tron.server.plist")
            let shipped = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: shippedPlist), options: [], format: nil) as? [String: Any])
            let plist: [String: Any] = [
                "Label": label, "ProgramArguments": [node.path, "--no-warnings", script.path],
                "WorkingDirectory": gateway.path, "EnvironmentVariables": environment,
                "RunAtLoad": true, "KeepAlive": shipped["KeepAlive"]!, "ThrottleInterval": 1,
                "ExitTimeOut": exitTimeoutOverride.map { $0 as Any } ?? shipped["ExitTimeOut"]!,
                "StandardOutPath": root.appendingPathComponent("process.log").path,
                "StandardErrorPath": root.appendingPathComponent("process.log").path,
            ]
            let plistURL = root.appendingPathComponent("job.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
            try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            bootstrapped = true
        } catch { cleanup(); throw error }
    }

    func port() throws -> Int { try #require(Int(String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8))) }
    func token() throws -> String {
        let data = try Data(contentsOf: home.appendingPathComponent("gateway/local-auth.json"))
        return try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["bearerToken"] as? String)
    }

    func waitUntilServing() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8),
               let first = text.split(separator: "\n").first, let value = Int32(first) { capturedPID = value }
            if logContains(event: "gateway.startup-budget") { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "Gateway fixture did not serve: \((try? String(contentsOf: root.appendingPathComponent("process.log"), encoding: .utf8)) ?? "no output")"])
    }

    func logContains(event: String) -> Bool {
        let text = (try? String(contentsOf: log, encoding: .utf8))
            ?? (try? String(contentsOf: root.appendingPathComponent("shutdown-log.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").contains { line in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            return record["event"] as? String == event
        }
    }

    func startAcceptedWork() async throws {
        let created = try await rpc("session.create", ["commandId": UUID().uuidString, "cwd": root.appendingPathComponent("project").path])
        let sessionID = try #require(created["sessionId"] as? String)
        _ = try await rpc("session.prompt", ["commandId": UUID().uuidString, "sessionId": sessionID, "text": "Wait for the fixture."])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("model-started").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("model-started").path), "real model request did not start")
    }

    private func rpc(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        let deadline = GatewayWebSocketTransport.Deadline(timeout: 10)
        let request = try GatewayRestartClient.makeRequest(host: "127.0.0.1", port: port(), token: token(), timeout: 10)
        let connection = try await GatewayWebSocketTransport.connect(request: request,
            protocolVersion: TronGatewayProtocolContract.protocolVersion,
            minimumProtocolVersion: TronGatewayProtocolContract.minimumProtocolVersion,
            clientID: UUID().uuidString, deadline: deadline)
        defer { connection.close() }
        let calls = method == "session.prompt"
            ? [("session.open", ["sessionId": params["sessionId"]!]), (method, params)] : [(method, params)]
        var result: [String: Any] = [:]
        for (name, arguments) in calls {
            let id = UUID().uuidString
            try await connection.send(jsonObject: ["type":"request", "id":id, "method":name, "params":arguments], deadline: deadline)
            var received = false
            while let data = try await connection.receiveData(deadline: deadline) {
                let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard frame?["id"] as? String == id else { continue }
                try #require(frame?["ok"] as? Bool == true, "RPC \(name) failed: \(String(describing: frame))")
                result = frame?["result"] as? [String: Any] ?? [:]
                received = true
                break
            }
            guard received else { throw GatewayRestartClient.Failure.malformedResponse }
        }
        return result
    }

    private func launchctl(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch,
            userInfo: [NSLocalizedDescriptionKey: "fixture launchctl \(args.first ?? "") failed: \(process.terminationStatus)"]) }
    }

    func didBootout() { bootstrapped = false }

    func stop() {
        // Retire only this randomly named fixture through its supervisor. Its
        // shipped ExitTimeOut owns cleanup; never signal a possibly reused PID.
        if bootstrapped {
            do { try launchctl(["bootout", service]); bootstrapped = false }
            catch { Issue.record("fixture supervisor cleanup failed: \(error)"); return }
        }
        for _ in 0..<1500 where isRunning { usleep(20_000) }
        if isRunning { Issue.record("fixture process did not retire") }
    }

    func cleanup() {
        stop()
        if !bootstrapped && !isRunning { try? FileManager.default.removeItem(at: root) }
    }
}
