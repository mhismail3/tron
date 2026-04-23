import AppKit
import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarIcon")
@MainActor
struct MenuBarIconTests {
    @Test("each tone resolves to a non-empty NSImage")
    func everyToneResolves() {
        for tone in [MenuBarTone.running, .stopped, .unauthorized, .unknown] {
            let image = MenuBarIcon.template(for: tone)
            #expect(image.size.width > 0, "tone \(tone) produced empty image")
            #expect(image.size.height > 0, "tone \(tone) produced empty image")
        }
    }

    @Test("running tone is non-template (colored), other tones are template")
    func templateFlag() {
        // Running uses solid color (so the green dot reads as alive); the
        // other tones rely on macOS's automatic light/dark adaptation
        // via template rendering.
        #expect(MenuBarIcon.template(for: .running).isTemplate == false)
        #expect(MenuBarIcon.template(for: .stopped).isTemplate == true)
        #expect(MenuBarIcon.template(for: .unauthorized).isTemplate == true)
        #expect(MenuBarIcon.template(for: .unknown).isTemplate == true)
    }
}
