import SwiftUI
import XCTest
@testable import TronMobile

/// The generalized JSON table is the standard metadata table without icons: it
/// qualifies each title with the value's JSON type and keeps one row geometry
/// with every other table in the app.
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

        // The type qualifier moves to its own line at accessibility sizes rather
        // than crushing the value into a sliver.
        let accessibilityHeight = Self.intrinsicHeight(
            jsonTable.environment(\.dynamicTypeSize, .accessibility3), width: width)
        XCTAssertGreaterThan(accessibilityHeight, jsonHeight)
    }

    func testJSONRowsQualifyTheirTitleWithTheValueType() async throws {
        let value: JSONValue = .object([
            "activeAsyncCapacity": .object(["mode": .string("single"), "max": .number(4)]),
            "mode": .string("single"),
            "results": .array([]),
        ])
        let view = TronStructuredJSONView(value: value, title: "Details", accent: .tronEmerald, showsRawDisclosure: false)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.tronBackground)
            .tronPresentation()

        try await withHost(view, size: CGSize(width: 402, height: 420)) { host in
            let elements = Self.accessibilityElements(in: host.view)
            for expected in ["Active Async Capacity, Object, 2 fields",
                             "Mode, Text, single",
                             "Results, List, 0 items"] {
                let row = try XCTUnwrap(elements.first { $0.label == expected }, "Missing row: \(expected)")
                XCTAssertTrue(row.traits.contains(.button), "A JSON row stays a progressive target")
                XCTAssertEqual(row.hint, "Opens the complete value")
            }
            XCTAssertTrue(elements.contains { $0.label == "DETAILS" }, "The section label uses the shared treatment")
            Self.attach(host.view, named: "structured-json-table", to: self)
        }
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

    private struct Element {
        let label: String
        let hint: String
        let traits: UIAccessibilityTraits
        let frame: CGRect
    }

    private static func accessibilityElements(in view: UIView) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        var collected: [Element] = []
        func walk(_ view: UIView) {
            for element in view.accessibilityElements ?? [] {
                guard let object = element as? NSObject else { continue }
                if seen.insert(ObjectIdentifier(object)).inserted {
                    collected.append(Element(label: object.accessibilityLabel ?? "",
                                             hint: object.accessibilityHint ?? "",
                                             traits: object.accessibilityTraits,
                                             frame: object.accessibilityFrame))
                }
                if let nested = element as? UIAccessibilityElement, let container = nested.accessibilityContainer as? UIView {
                    walk(container)
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return collected
    }

    private static func intrinsicHeight(_ content: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: content)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func attach(_ view: UIView, named name: String, to testCase: XCTestCase) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private func withHost<Content: View>(
        _ content: Content, size: CGSize,
        check: (UIHostingController<Content>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "JSON table fixture appeared")
        let host = StructuredJSONTableHostingController(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [appeared], timeout: 2)
        host.view.layoutIfNeeded()
        try await check(host)
    }
}

@MainActor
private final class StructuredJSONTableHostingController<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}
