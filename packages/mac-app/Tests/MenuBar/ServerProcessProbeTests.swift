import Testing
@testable import TronMac

@Suite("ServerProcessProbe")
struct ServerProcessProbeTests {
    @Test("parses the first unique listening PID")
    func parseListeningPID() {
        #expect(ServerProcessProbe.parseFirstPID("24680\n24680\n") == 24680)
        #expect(ServerProcessProbe.parseFirstPID(" \n13579\n") == 13579)
        #expect(ServerProcessProbe.parseFirstPID("not-a-pid\n") == nil)
    }

    @Test("recognizes tron dev command lines")
    func devCommandRecognition() {
        #expect(ServerProcessProbe.isDevServerCommand(
            "/Users/example/.tron/system/run/Tron-Dev.app/Contents/MacOS/tron --port 9847"
        ))
        #expect(!ServerProcessProbe.isDevServerCommand(
            "/Applications/Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron --port 9847"
        ))
    }
}
