import Darwin
import Foundation
import Testing
@testable import TronMac

@Suite("CodeSignatureProbe")
struct CodeSignatureProbeTests {
    @Test("noisy verification and identity drain without blocking", arguments: ["--verify", "-dv"])
    func noisyCheck(stage: String) async throws {
        let fixture = try SubprocessFixture(customScript: script(stage: stage, action: noise(bytes: 200_000)))
        defer { fixture.stop() }
        let calls = SignatureCommands()
        let result = await probe(fixture, calls: calls)
        #expect(result == nil)
        #expect(await calls.stages == ["--verify", "-dv"])
        #expect(!fixture.watchdogFired)
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("hung signature observations retire their owned client", arguments: ["--verify", "-dv"])
    func hungCheck(stage: String) async throws {
        let fixture = try SubprocessFixture(customScript: script(stage: stage, action: "trap '' TERM; read value < \"$1/release\""))
        defer { fixture.stop() }
        let calls = SignatureCommands()
        let started = ContinuousClock.now
        let pending = Task { await probe(fixture, calls: calls) }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        #expect(await pending.value == unavailable(stage: stage, fixture: fixture))
        #expect(started.duration(to: .now) < .seconds(7))
        #expect(!fixture.watchdogFired)
        #expect(await calls.stages == (stage == "--verify" ? ["--verify"] : ["--verify", "-dv"]))
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("cancellation at either query cannot authorize registration", arguments: ["--verify", "-dv"])
    func cancelledCheck(stage: String) async throws {
        let fixture = try SubprocessFixture(customScript: script(stage: stage, action: "trap '' TERM; read value < \"$1/release\""))
        defer { fixture.stop() }
        let calls = SignatureCommands()
        let pending = Task { await probe(fixture, calls: calls) }
        let pid = await fixture.readyPID()
        #expect(pid != nil)
        let started = ContinuousClock.now
        pending.cancel()
        #expect(await pending.value == unavailable(stage: stage, fixture: fixture))
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(!fixture.watchdogFired)
        #expect(await calls.stages == (stage == "--verify" ? ["--verify"] : ["--verify", "-dv"]))
        if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test("oversized successful diagnostic prefixes fail closed", arguments: ["--verify", "-dv"])
    func oversizedCheck(stage: String) async throws {
        let fixture = try SubprocessFixture(customScript: script(stage: stage, action: noise(bytes: 1_200_000)))
        defer { fixture.stop() }
        #expect(await probe(fixture, calls: SignatureCommands()) == unavailable(stage: stage, fixture: fixture))
        #expect(!fixture.watchdogFired)
    }

    @Test("native command failure stays distinct from unavailable capture", arguments: ["--verify", "-dv"])
    func failedCheck(stage: String) async throws {
        let fixture = try SubprocessFixture(customScript: script(stage: stage, action: "exit 7"))
        defer { fixture.stop() }
        let calls = SignatureCommands()
        let identity = stage == "-dv" ? " identity" : ""
        #expect(await probe(fixture, calls: calls) == "\(fixture.root.lastPathComponent) is present but its code signature\(identity) is invalid")
        #expect(await calls.stages == (stage == "--verify" ? ["--verify"] : ["--verify", "-dv"]))
    }

    private func probe(_ fixture: SubprocessFixture, calls: SignatureCommands) async -> String? {
        await ExistingInstallDetector.bundleSignatureProblem(of: fixture.root, expectedBundleIdentifier: "com.tron.server") { executable, arguments, policy in
            #expect(executable.path == "/usr/bin/codesign")
            #expect(policy == .observation)
            let expected = arguments.first == "--verify"
                ? ["--verify", "--deep", "--strict", "--verbose=2", fixture.root.path]
                : ["-dv", "--verbose=4", fixture.root.path]
            #expect(arguments == expected)
            await calls.record(arguments)
            // Exercise the real observation owner with the production-selected
            // policy, substituting only the owned executable/fixture argument.
            return await Subprocess.run(executable: fixture.shell, arguments: fixture.arguments + arguments, policy: policy)
        }
    }

    private func unavailable(stage: String, fixture: SubprocessFixture) -> String {
        let identity = stage == "-dv" ? " identity" : ""
        return "\(fixture.root.lastPathComponent) is present but its code signature\(identity) could not be checked"
    }

    private func noise(bytes: Int) -> String {
        // exec preserves the exact owned helper PID; there is no child tree.
        "exec /usr/bin/awk 'BEGIN { for (i=0; i<\(bytes); i++) printf \"x\"; print \"\" }'"
    }

    private func script(stage: String, action: String) -> String {
        """
        if [ "$2" = "-dv" ]; then
            printf '%s\\n' 'Identifier=com.tron.server' 'TeamIdentifier=TEAM123456' >&2
        fi
        if [ "$2" = "\(stage)" ]; then
            printf '%s\\n' "$$" > "$1/ready"
            \(action)
        fi
        """
    }
}

private actor SignatureCommands {
    private(set) var stages: [String] = []
    func record(_ arguments: [String]) { stages.append(arguments[0]) }
}
