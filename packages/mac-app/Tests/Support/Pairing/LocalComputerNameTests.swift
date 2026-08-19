import Testing
@testable import TronMac

@Suite("LocalComputerName")
struct LocalComputerNameTests {
    @Test("Computer Name wins over host candidates")
    func computerNameWins() {
        let name = LocalComputerName.preferredName(
            computerName: "Studio Mac",
            localizedHostName: "studio.local",
            hostName: "studio-host"
        )
        #expect(name == "Studio Mac")
    }

    @Test("adds a Dev suffix only for isolated pairing")
    func pairingName() {
        #expect(LocalComputerName.pairingName("Moose's MacBook Server", isDev: false) == "Moose's MacBook Server")
        #expect(LocalComputerName.pairingName("Moose's MacBook Server", isDev: true) == "Moose's MacBook Server (Dev)")
    }

    @Test("Uses localized host, host, then default")
    func candidateOrder() {
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
            defaultName: "Default Mac"
        ) == "Default Mac")
    }
}
