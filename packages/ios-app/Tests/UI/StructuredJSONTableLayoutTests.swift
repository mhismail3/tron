import SwiftUI
import XCTest
@testable import TronMobile

/// Native sizing stays here; typed labels, button semantics and navigation are
/// observed by TronAccessibilityUITests through the real accessibility client.
@MainActor
final class StructuredJSONTableLayoutTests: XCTestCase {
    func testJSONTableSharesTheStandardRowGeometry() throws {
        let value: JSONValue = .object([
            "activeAsyncCapacity": .object(["mode": .string("single"), "max": .number(4)]),
            "mode": .string("single"),
            "results": .array([]),
        ])
        let jsonTable = TronStructuredJSONView(value: value, title: "Details", accent: .tronEmerald,
                                               showsRawDisclosure: false)
            .padding(18)
        let standardTable = TronTechnicalMetadataSection(title: "Details", items: [
            TronTechnicalMetadataItem(title: "Active Async Capacity", value: "2 fields", icon: "number"),
            TronTechnicalMetadataItem(title: "Mode", value: "single", icon: "number"),
            TronTechnicalMetadataItem(title: "Results", value: "0 items", icon: "number"),
        ], accent: .tronEmerald)
            .padding(18)
        let width: CGFloat = 366
        let jsonHeight = Self.intrinsicHeight(jsonTable, width: width)
        let standardHeight = Self.intrinsicHeight(standardTable, width: width)
        XCTAssertEqual(jsonHeight, standardHeight, accuracy: 1,
                       "One component owns the section label, card, divider, and row geometry")
        let accessibilityHeight = Self.intrinsicHeight(
            jsonTable.environment(\.dynamicTypeSize, .accessibility3), width: width)
        XCTAssertGreaterThan(accessibilityHeight, jsonHeight)
    }

    func testPlainMetadataRowsStackAtAccessibilitySizes() throws {
        let rows = [
            TronMetadataTableRow(id: "timezone", title: "Timezone", value: "America/Los_Angeles"),
            TronMetadataTableRow(id: "policy", title: "After downtime", value: "Run latest missed occurrence"),
        ]
        let table = TronMetadataTable(title: "Schedule", accent: .tronAutomation, rows: rows)
        let standard = Self.intrinsicHeight(table, width: 326)
        let accessible = table.environment(\.dynamicTypeSize, .accessibility3)
        XCTAssertGreaterThan(Self.intrinsicHeight(accessible, width: 326), standard)
    }

    private static func intrinsicHeight(_ content: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: content)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
