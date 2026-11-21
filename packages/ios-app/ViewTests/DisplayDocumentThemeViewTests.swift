import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class DisplayDocumentThemeViewTests: ShuffledTestCase {
    func testSiblingMarkdownImageAndUnavailableTargets() async throws {
        for light in [true, false] {
            try await mounted(["-tron-chat-display-fixture", "-display-document-theme", "-display-document-images",
                               "-display-document-home"] + (light ? ["-polish-light"] : []), theme: .burgundy) { app in
                try await openReader(app, "Home audit report")
                try await app.until("the sibling image") { app.element("Preview") != nil }
                let frame = app.element("Preview")!.accessibilityFrame
                XCTAssertGreaterThan(frame.width, 100, "Sibling capture is readable, not an icon")
                let inset = frame.insetBy(dx: 8, dy: 8), third = inset.height / 3
                let red = try XCTUnwrap(app.chroma(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: third), range: 45)).ink
                let blue = try XCTUnwrap(app.chroma(CGRect(x: inset.minX, y: inset.maxY - third, width: inset.width, height: third), range: 45)).ink
                XCTAssertGreaterThan(red[0], red[2] + 0.5, "Actual sibling PNG pixels render red above blue")
                XCTAssertGreaterThan(blue[2], blue[0] + 0.5, "Actual sibling PNG pixels render red above blue")
                try await app.until("the unavailable targets") {
                    app.staticText("Missing: image unavailable.") != nil && app.staticText("Outside: image unavailable.") != nil
                }
                try await app.activate("Done")
                try await app.until("the reader is dismissed") { app.element("Preview") == nil }
                let chip = try XCTUnwrap(app.labelled("Home audit report"))
                XCTAssertTrue(app.onScreen(chip), "The reader remains dismissible")
            }
        }
    }

    func testHomeAndSessionMarkdownFollowPrimaryTheme() async throws {
        for theme in [ThemeColor.burgundy, .oliveGold] {
            for light in [true, false] {
                for home in [true, false] {
                    try await mounted(["-tron-chat-display-fixture", "-display-document-theme"] + (light ? ["-polish-light"] : [])
                                      + (home ? ["-display-document-home"] : []), theme: theme) { app in
                        let title = home ? "Home audit report" : "Session summary"
                        try await openReader(app, title)
                        try await app.until("the reader chrome and link") {
                            app.navigationTitle(title) != nil && app.button("Done") != nil && evidenceLink(app) != nil
                        }
                        let frames = [app.navigationTitle(title)!.accessibilityFrame, app.button("Done")!.accessibilityFrame,
                                      evidenceLink(app)!.accessibilityFrame]
                        for (name, frame) in zip(["title", "Done", "Markdown link"], frames) {
                            let hue = try XCTUnwrap(app.chroma(frame, range: 45)).ink
                            if theme == .burgundy {
                                XCTAssertGreaterThan(hue[0], hue[1] + 0.5, "\(name) must be burgundy: \(hue)")
                                XCTAssertGreaterThan(hue[0], hue[2] + 0.15, "\(name) must be burgundy: \(hue)")
                            } else {
                                XCTAssertGreaterThan(hue[0], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                                XCTAssertGreaterThan(hue[1], hue[2] + 0.5, "\(name) must be olive gold: \(hue)")
                            }
                        }
                        try await app.activate("Done")
                        try await app.until("Done dismisses the document") { app.navigationTitle(title) == nil }
                    }
                }
            }
        }
    }

    func testMountedReaderUpdatesThemeAndAppearance() async throws {
        try await mounted(["-tron-chat-display-fixture", "-display-document-updates"], theme: .burgundy) { app in
            try await app.activate("Open theme-change reader")
            try await app.until("the reader link") { evidenceLink(app) != nil }
            let originalMinY = evidenceLink(app)!.accessibilityFrame.minY
            for olive in [false, true] {
                if olive { try await app.activate("Switch reader theme") }
                for appearanceChange in [false, true] {
                    if appearanceChange { try await app.activate("Switch reader appearance") }
                    try await app.until("the reader adopts theme olive=\(olive) appearanceChange=\(appearanceChange)") {
                        tinted(app, olive: olive)
                    }
                    XCTAssertEqual(evidenceLink(app)!.accessibilityFrame.minY, originalMinY, accuracy: 1,
                                   "Theme changes preserve reader layout")
                }
            }
            try await app.activate("Done")
            try await app.until("the same sheet remains dismissible") {
                app.button("Open theme-change reader").map(app.onScreen) == true
            }
        }
    }

    private func openReader(_ app: MountedFixture, _ title: String) async throws {
        var chip: NSObject?
        try await app.until("the \(title) chip") {
            chip = app.labelled(title)
            return chip != nil
        }
        XCTAssertTrue(chip!.accessibilityActivate(), "\(title) refused activation")
    }
}

@MainActor
private func evidenceLink(_ app: MountedFixture) -> NSObject? {
    MountedFixture.elements(in: app.top).last { $0.accessibilityLabel?.contains("Navigation evidence") == true }
}

@MainActor
private func tinted(_ app: MountedFixture, olive: Bool) -> Bool {
    let frames = [app.navigationTitle("Theme change reader")?.accessibilityFrame, app.button("Done")?.accessibilityFrame,
                  evidenceLink(app)?.accessibilityFrame]
    return frames.allSatisfy { frame in
        guard let frame, let hue = app.chroma(frame, range: 45)?.ink else { return false }
        return olive ? hue[0] > hue[2] + 0.5 && hue[1] > hue[2] + 0.5 : hue[0] > hue[2] + 0.15 && hue[0] > hue[1] + 0.5
    }
}
