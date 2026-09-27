import SwiftUI
import Testing
import UIKit
@testable import TronMobile

/// `Color(lightHex:darkHex:)` parses its hex values once and only selects in
/// its dynamic provider. Guards the failure modes the single-appearance parity
/// gates miss: the provider selecting the wrong parsed color for a style
/// (including the unspecified style, which renders the light value) or the
/// parsed components drifting from `UIColor(hex:)`.
@Suite("Tron theme colors")
struct TronThemeColorTests {
    @Test("adaptive palette colors resolve each interface style to its exact hex")
    func adaptiveColorsResolvePerStyle() {
        let color = UIColor(Color(lightHex: "#0E7490", darkHex: "#67E8F9"))
        let light = UIColor(red: 0x0E / 255.0, green: 0x74 / 255.0, blue: 0x90 / 255.0, alpha: 1)
        let dark = UIColor(red: 0x67 / 255.0, green: 0xE8 / 255.0, blue: 0xF9 / 255.0, alpha: 1)
        #expect(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) == light)
        #expect(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) == dark)
        #expect(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .unspecified)) == light)
        #expect(UIColor(hex: "#67E8F9") == dark)
    }
}
