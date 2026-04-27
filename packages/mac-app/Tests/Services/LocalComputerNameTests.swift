import Testing
@testable import TronMac

@Suite("LocalComputerName")
struct LocalComputerNameTests {
    @Test("Computer Name wins over host fallbacks")
    func computerNameWins() {
        let name = LocalComputerName.preferredName(
            computerName: "Studio Mac",
            localizedHostName: "studio.local",
            hostName: "studio-host"
        )
        #expect(name == "Studio Mac")
    }

    @Test("Falls back through localized host, host, then default")
    func fallbackOrder() {
        #expect(LocalComputerName.preferredName(
            computerName: " ",
            localizedHostName: "Living Room Mac",
            hostName: "host"
        ) == "Living Room Mac")

        #expect(LocalComputerName.preferredName(
            computerName: nil,
            localizedHostName: "\n",
            hostName: "host"
        ) == "host")

        #expect(LocalComputerName.preferredName(
            computerName: nil,
            localizedHostName: nil,
            hostName: nil,
            fallback: "Fallback Mac"
        ) == "Fallback Mac")
    }
}
