import Foundation
import Testing
@testable import TronMac

struct SubprocessTests {
    @Test("a fast-exit child completes exactly once")
    func fastExit() async {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"]
        )
        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("drains stdout and stderr while a noisy child is running")
    func drainsBothPipes() async {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf o; printf e >&2; i=$((i+1)); done"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 20_000)
        #expect(result.stderr.count == 20_000)
    }
}
