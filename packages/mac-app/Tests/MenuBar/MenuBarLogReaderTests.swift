import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {
    @Test("uses the supported rendered-log file contract")
    func commandArguments() {
        let output = URL(fileURLWithPath: "/tmp/tron-logs.txt")
        #expect(MenuBarLogReader.commandArguments(limit: 200, outputFile: output) == [
            "logs",
            "-n",
            "200",
            "-o",
            "/tmp/tron-logs.txt",
        ])
    }
}
