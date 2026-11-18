import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeUsageCardViewTests: ShuffledTestCase {
    func testUsageCardRowsShowWindowColumns() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-dashboard-workers", "-dashboard-view-home",
                           "-home-usage-long-name"]) { app in
            try await app.until("the usage card and its layout probe") {
                app.element("home-usage-card")?.accessibilityLabel?.contains("Cloudflare AI Gateway, 48% used (Weekly)") == true
                    && app.element("fixture.home-usage-layout")?.accessibilityLabel?.contains("cloudflare-ai-gateway.column0.bar=") == true
            }
            let cardLabel = app.element("home-usage-card")!.accessibilityLabel ?? ""
            XCTAssertTrue(cardLabel.hasPrefix("Anthropic, 42% used (5h) · 18% used (Weekly)"), cardLabel)
            var summary = ""
            _ = try await app.still("the usage layout") {
                summary = app.element("fixture.home-usage-layout")?.accessibilityLabel ?? ""
                return summary.split(separator: ";").flatMap { $0.split(separator: "=").last?.split(separator: ",").compactMap { Double($0) } ?? [] }
                    .map { $0 / 1000 }
            }
            var frames: [String: CGRect] = [:]
            for entry in summary.split(separator: ";") {
                let pair = entry.split(separator: "=")
                let v = pair[1].split(separator: ",").compactMap { Double($0) }
                frames[String(pair[0])] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            }
            let cardFrame = try XCTUnwrap(frames["card"])
            for (provider, columns) in [("anthropic", 2), ("openai-codex", 2), ("cloudflare-ai-gateway", 1)] {
                let name = try XCTUnwrap(frames["\(provider).name"], summary)
                XCTAssertNil(frames["\(provider).column\(columns)"], "\(provider) has \(columns) column(s)")
                var previous: CGRect?
                for index in 0..<columns {
                    let column = try XCTUnwrap(frames["\(provider).column\(index)"], summary)
                    let bar = try XCTUnwrap(frames["\(provider).column\(index).bar"], summary)
                    XCTAssertEqual(bar.width, column.width, accuracy: 1, "\(provider) bar spans its own column")
                    XCTAssertEqual(bar.minX, column.minX, accuracy: 1)
                    XCTAssertEqual(bar.maxY, column.maxY, accuracy: 1, "\(provider) bar sits under its copy")
                    XCTAssertEqual(bar.height, 5, accuracy: 0.5)
                    let fill = try XCTUnwrap(frames["\(provider).column\(index).fill"], summary)
                    XCTAssertEqual(fill.minX, bar.minX, accuracy: 0.5, "\(provider) fill starts at its track")
                    XCTAssertEqual(fill.height, bar.height, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(fill.width + 0.01, fill.height, "\(provider) fill keeps its rounded ends")
                    XCTAssertGreaterThan(bar.width / cardFrame.width, 0.2, "\(provider) bar is about a quarter of the card")
                    XCTAssertLessThan(bar.width / cardFrame.width, 0.34, "\(provider) bar no longer spans the card")
                    XCTAssertEqual(column.midY, name.midY, accuracy: 1, "\(provider) name is centered against its columns")
                    XCTAssertGreaterThan(column.minX, name.maxX, "\(provider) name keeps clear of its columns")
                    if let previous {
                        XCTAssertGreaterThan(column.minX, previous.maxX, "windows sit side by side")
                        XCTAssertEqual(column.minY, previous.minY, accuracy: 0.5)
                    }
                    previous = column
                }
                XCTAssertEqual(try XCTUnwrap(previous).maxX, cardFrame.maxX - 12, accuracy: 1, "\(provider) columns are right-aligned")
            }
            let small = try XCTUnwrap(frames["openai-codex.column1.fill"], summary)
            let smallTrack = try XCTUnwrap(frames["openai-codex.column1.bar"], summary)
            XCTAssertLessThan(smallTrack.width * 0.02, small.height, "the fixture share is below one bar height")
            XCTAssertEqual(small.width, small.height, accuracy: 0.5, "a small share is a round dot")
            let large = try XCTUnwrap(frames["anthropic.column0.fill"], summary)
            let largeTrack = try XCTUnwrap(frames["anthropic.column0.bar"], summary)
            XCTAssertEqual(large.width, largeTrack.width * 0.42, accuracy: 1, "a larger share stays proportional")
        }
    }
}
