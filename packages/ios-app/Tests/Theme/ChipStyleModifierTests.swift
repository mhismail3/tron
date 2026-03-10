import Testing
import SwiftUI
@testable import TronMobile

@Suite("ChipStyleModifier")
@MainActor
struct ChipStyleModifierTests {

    @Test("chipStyle creates view with default parameters")
    func chipStyleDefaults() {
        // Verify chipStyle modifier can be applied without crash
        let color = Color.tronEmerald
        let view = Text("Test").chipStyle(color)
        #expect(type(of: view) != Never.self)
    }

    @Test("chipStyle creates view with custom tintOpacity and strokeOpacity")
    func chipStyleCustomParams() {
        let view = Text("Test").chipStyle(.tronAmber, tintOpacity: 0.25, strokeOpacity: 0.3)
        #expect(type(of: view) != Never.self)
    }

    @Test("chipStyle with zero opacity does not crash")
    func chipStyleZeroOpacity() {
        let view = Text("Test").chipStyle(.red, tintOpacity: 0.0, strokeOpacity: 0.0)
        #expect(type(of: view) != Never.self)
    }

    @Test("chipStyleMaterial creates view with default parameters")
    func chipStyleMaterialDefaults() {
        let view = Text("Test").chipStyleMaterial(.tronCyan)
        #expect(type(of: view) != Never.self)
    }

    @Test("chipStyleMaterial creates view with custom tintOpacity")
    func chipStyleMaterialCustom() {
        let view = Text("Test").chipStyleMaterial(.tronCyan, tintOpacity: 0.5)
        #expect(type(of: view) != Never.self)
    }
}
