import Foundation
import Testing

@Suite("Embedded Cua process ownership (offline)", .serialized)
@MainActor struct CuaProcessOwnerTests {
    @Test func rejectedSignatureNeverLaunchesChild() async throws {
        try await fixture(verified: false) { root, owner in
            try Data().write(to: root.appendingPathComponent("release"))
            owner.start(); await owner.retire()
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
            #expect(owner.endpoint() == nil)
        }
    }

    @Test func concurrentRetirementJoinsTheSameRealChildExit() async throws {
        try await fixture { root, owner in
            try #require(owner.start(), "Fixture process must be admitted before lifecycle assertions")
            try await waitFor { owner.endpoint() != nil }
            let endpoint = try #require(owner.endpoint())
            #expect(endpoint.socket.utf8.count < 104)
            let attributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: endpoint.socket).deletingLastPathComponent().path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
            var firstDone = false, secondDone = false, secondEntered = false
            let first = Task { await owner.retire(); firstDone = true }
            try await waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("eof").path) }
            let second = Task { secondEntered = true; await owner.retire(); secondDone = true }
            try await waitFor { secondEntered }
            for _ in 0..<20 { await Task.yield() }
            #expect(!firstDone && !secondDone, "Neither caller may claim retirement while the admitted child is still blocked")
            #expect(owner.endpoint() == nil)
            owner.start() // Startup is sealed while joining, not just afterward.
            try Data().write(to: root.appendingPathComponent("release"))
            await first.value; await second.value
            #expect(firstDone && secondDone)
            #expect(!FileManager.default.fileExists(atPath: endpoint.socket))
            let data = try Data(contentsOf: root.appendingPathComponent("ready"))
            let args = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(args["telemetry"] as? String == "false")
            #expect((args["arguments"] as? [String])?.contains("--parent-liveness-stdio") == true)
            #expect((args["arguments"] as? [String])?.contains("--permission-mode") == true)
        }
    }

    @Test func retireBeforeStartCannotCreateALateChild() async throws {
        try await fixture { root, owner in
            await owner.retire(); owner.start(); await owner.retire()
            #expect(owner.endpoint() == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        }
    }

    private func fixture(verified: Bool = true, body: (URL, CuaProcessOwner) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-owner-test-\(UUID())")
        let executable = root.appendingPathComponent("Contents/Library/Native/cua-driver")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = String(data: try JSONEncoder().encode(root.path), encoding: .utf8)!
        let script = """
        #!/usr/bin/python3
        import json,os,socket,sys,time
        from pathlib import Path
        root=Path(json.loads(r'''\(encoded)'''))
        sys.stderr=(root/'error').open('w')
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        s.bind(sys.argv[sys.argv.index('--socket')+1]);s.listen(1)
        (root/'ready').write_text(json.dumps({'arguments':sys.argv[1:],'telemetry':os.environ.get('CUA_DRIVER_RS_TELEMETRY_ENABLED')}))
        sys.stdin.buffer.read()
        (root/'eof').write_text('observed')
        while not (root/'release').exists():time.sleep(.005)
        s.close()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let owner = CuaProcessOwner(bundle: root, verifyExecutable: { _ in verified })
        do { try await body(root, owner) }
        catch {
            if let diagnostic = try? String(contentsOf: root.appendingPathComponent("error"), encoding: .utf8) { print("Cua fixture failure: \(diagnostic)") }
            try? Data().write(to: root.appendingPathComponent("release")); await owner.retire()
            try? FileManager.default.removeItem(at: root); throw error
        }
        try Data().write(to: root.appendingPathComponent("release")); await owner.retire()
        try FileManager.default.removeItem(at: root)
    }
    private func waitFor(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OwnerTestError.timeout(line)
    }
    private enum OwnerTestError: Error { case timeout(Int) }
}
