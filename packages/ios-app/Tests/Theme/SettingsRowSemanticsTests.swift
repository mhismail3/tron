import Testing
@testable import TronMobile

@Suite("Settings row semantics")
struct SettingsRowSemanticsTests {
    @Test("stable secondary copy uses informational typography")
    func stableCopyIsInformational() {
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: nil,
            placement: .secondaryLine
        ) == .informational)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: nil,
            placement: .trailing
        ) == .informational)
    }

    @Test("a separate trailing control moves the changing value to the secondary line")
    func controlledValuesUseSecondaryLine() {
        let placement = TronSettingsRowSemantics.valuePlacement(hasTrailingControl: true)
        #expect(placement == .secondaryLine)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: "Connected",
            placement: placement
        ) == .dynamicValue)
    }

    @Test("a row without a trailing control right aligns its changing value")
    func uncontrolledValuesUseTrailingPosition() {
        let placement = TronSettingsRowSemantics.valuePlacement(hasTrailingControl: false)
        #expect(placement == .trailing)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: "GPT 5.6 Luna",
            placement: placement
        ) == .informational)
    }
}
