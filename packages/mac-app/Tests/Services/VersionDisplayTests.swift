import Testing

@testable import TronMac

@Suite("VersionDisplay")
struct VersionDisplayTests {
    @Test("beta display trims zero patch")
    func betaDisplay() {
        #expect(VersionDisplay.label(for: "0.1.0-beta.1") == "v0.1 (Beta 1)")
    }

    @Test("stable display trims zero patch")
    func stableDisplay() {
        #expect(VersionDisplay.label(for: "0.1.0") == "v0.1")
    }

    @Test("patch display keeps non-zero patch")
    func patchDisplay() {
        #expect(VersionDisplay.label(for: "0.1.1") == "v0.1.1")
    }

    @Test("scoped tag display is accepted")
    func scopedTagDisplay() {
        #expect(VersionDisplay.label(for: "mac-v0.2.0-beta.3") == "v0.2 (Beta 3)")
    }
}
