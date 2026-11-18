import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SharedPrimaryAccentsViewTests: ShuffledTestCase {
    func testBurgundyLight() async throws { try await journey(.burgundy, "light") }
    func testBurgundyDark() async throws { try await journey(.burgundy, "dark") }
    func testEmeraldLight() async throws { try await journey(.emerald, "light") }
    func testEmeraldDark() async throws { try await journey(.emerald, "dark") }
    func testOliveGoldLight() async throws { try await journey(.oliveGold, "light") }
    func testOliveGoldDark() async throws { try await journey(.oliveGold, "dark") }

    private func journey(_ theme: ThemeColor, _ mode: String) async throws {
        try await mounted(["-tron-session-configuration-fixture", "-manage-session-review", "-history-large",
                           "-fixture-appearance", mode], theme: theme) { app in
            try await app.activate("Stop session")
            try await app.until("Manage Session opens") { app.navigationTitle("Manage Session") != nil }
            try await app.expandTopSheet()
            let progress = try await revealed(app, "Context used")
            XCTAssertEqual(progress.accessibilityValue, "31 percent")
            try await verify(app, ["Context used"], title: "Manage Session", name: "\(theme)-\(mode)-usage")
            _ = try await revealed(app, "Session History")
            try await app.activate("Session History")
            try await app.until("Session History opens") { app.element("history-row-h-6732-status") != nil }
            try await app.expandTopSheet()
            try await verify(app, ["history-row-h-6732-status", "history-row-h-6731-leading"],
                             title: "Session History", name: "\(theme)-\(mode)-history")
            _ = try await revealed(app, "history-row-h-6727-leading")
            try await verify(app, ["history-row-h-6727-leading"], title: "Session History", name: "\(theme)-\(mode)-history-prompt")
        }
        try await mounted(["-tron-agent-instructions-fixture"] + (mode == "dark" ? ["-home-dark"] : []), theme: theme) { app in
            try await app.until("the instructions sections") { app.element("agent-instructions-section-tools") != nil }
            try await app.expandTopSheet()
            for (section, indices) in [("tools", [0, 1]), ("rules", [0, 2]), ("skills", [0])] {
                _ = try await revealed(app, "agent-instructions-section-\(section)")
                try await app.activate("agent-instructions-section-\(section)")
                let title = section.capitalized
                try await app.until("\(title) opens") { app.navigationTitle(title) != nil }
                try await app.expandTopSheet()
                try await verify(app, indices.map { "agent-instructions-entry-\(section).\($0)" }, title: title,
                                 name: "\(theme)-\(mode)-\(section)") { frame in
                    CGRect(x: frame.maxX - 70, y: frame.minY, width: 70, height: frame.height)
                }
                try await app.activate("Done")
                try await app.until("Instructions returns") { app.navigationTitle("Instructions") != nil }
            }
        }
    }

    private func verify(_ app: MountedFixture, _ keys: [String], title: String, name: String,
                        area: (CGRect) -> CGRect = { $0 }) async throws {
        try await app.until("\(name) areas exist") { keys.allSatisfy { app.element($0) != nil } }
        do {
            _ = try await app.still("\(name) inks") {
                guard let title = app.navigationTitle(title).flatMap({ ink(app, $0.accessibilityFrame) }) else { return nil }
                let areas = keys.compactMap { app.element($0).flatMap { ink(app, area($0.accessibilityFrame)) } }
                return areas.count == keys.count ? title + areas.flatMap { $0 } : nil
            }
        } catch is FixtureNotReady {
            for (index, key) in keys.enumerated() {
                let frame = app.element(key).map { area($0.accessibilityFrame) } ?? .null
                if app.element(key).flatMap({ ink(app, area($0.accessibilityFrame)) }) == nil {
                    XCTFail("Missing rendered accent: \(name) area \(index) \(frame)")
                }
            }
            if app.navigationTitle(title).flatMap({ ink(app, $0.accessibilityFrame) }) == nil {
                XCTFail("Missing primary title ink: \(name)")
            }
            return
        }
        let image = app.render()
        guard let expected = app.navigationTitle(title).flatMap({ ink(app, $0.accessibilityFrame, image: image) }) else {
            return XCTFail("Missing primary title ink: \(name)")
        }
        for (index, key) in keys.enumerated() {
            let frame = area(app.element(key)!.accessibilityFrame)
            guard let actual = ink(app, frame, image: image) else {
                XCTFail("Missing rendered accent: \(name) area \(index) \(frame)"); continue
            }
            let distance = zip(actual, expected).map { abs($0 - $1) }.max()!
            print("SHARED_PRIMARY \(name)[\(index)] actual=\(actual) primary=\(expected) distance=\(distance)")
            XCTAssertLessThan(distance, 0.15, "\(name)[\(index)] must match rendered primary title ink")
        }
    }

    private func ink(_ app: MountedFixture, _ area: CGRect, image: UIImage? = nil) -> [Double]? {
        app.chroma(area, range: 60, image: image).flatMap { $0.count >= 5 ? $0.ink : nil }
    }
}
