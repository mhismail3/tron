import AppKit
import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarIcon")
@MainActor
struct MenuBarIconTests {
    @Test("each server state resolves to a tinted logo image")
    func everyStateResolves() {
        for state in [
            ServerStatusState.checking,
            .running(version: "0.5.0", port: 9847),
            .busy(.restarting),
            .paused,
            .failed(reason: "timeout"),
            .unauthorized,
        ] {
            let image = MenuBarIcon.image(for: state)
            #expect(image.size == MenuBarIcon.size, "state \(state) produced wrong image size")
            #expect(image.isTemplate == false, "state \(state) should use explicit tint rendering")
        }
    }

    @Test("tone colors are explicit and distinct")
    func toneColors() {
        #expect(MenuBarIcon.color(for: .running) != MenuBarIcon.color(for: .attention))
        #expect(MenuBarIcon.color(for: .attention) != MenuBarIcon.color(for: .failed))
        #expect(MenuBarIcon.color(for: .paused) != MenuBarIcon.color(for: .failed))
    }
}
