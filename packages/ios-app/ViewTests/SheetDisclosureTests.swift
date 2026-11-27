import XCTest
import TronMobileCore
@testable import TronMobile

@MainActor
final class SheetDisclosureTests: ShuffledTestCase {
    private let sha = "b29af0f9c1d2e3f40516273849a0b1c2d3e4f506"
    private let from = "0123456789abcdef0123456789abcdef01234567"

    private func review(title: String, items: [JSONValue]) throws -> ChangeReview {
        try JSONValue.object([
            "digest": .string(String(repeating: "d", count: 64)), "title": .string(title), "requiresTap": .bool(true),
            "reason": .string("Pick up the provider fix."), "items": .array(items),
        ]).decode(ChangeReview.self)
    }

    func testReviewLeadsWithAReadableSummaryAndKeepsEveryExactValueInTechnicalDetails() throws {
        let source = "git:github.com/acme/pi-antigravity"
        let exact = "{\"operation\":\"package.update\",\"source\":\"\(source)\",\"version\":\"\(sha)\"}"
        let package = try review(title: "Update \(source) to commit \(sha)", items: [
            .object(["label": .string("Package \(source)"), "before": .string(from), "after": .string(sha),
                     "detail": .string("\(source)\nUser package (global)\nInstaller: npm with 2 argument(s); sha256 0123456789ab"),
                     "exact": .string(exact)]),
            .object(["label": .string("Configured source"), "before": .string(source), "after": .string("\(source)@\(sha)"),
                     "detail": .string("sources.packages (global) pin")]),
        ])
        let presentation = ChangeReviewPresentation(package)
        XCTAssertEqual(presentation.title, "Update pi-antigravity to commit b29af0f")
        XCTAssertEqual(presentation.reason, "Pick up the provider fix.")
        XCTAssertEqual(presentation.items.map(\.label), ["Package pi-antigravity", "Configured source"])
        XCTAssertEqual(presentation.items.map(\.before), ["0123456", "pi-antigravity"])
        XCTAssertEqual(presentation.items.map(\.after), ["b29af0f", "pi-antigravity @ b29af0f"])
        XCTAssertEqual(presentation.items.map(\.note), ["Installer: npm with 2 argument(s); sha256 0123456789ab", nil])
        let summary = ([presentation.title] + presentation.items.flatMap { [$0.label, $0.before, $0.after] }).joined(separator: "\n")
        XCTAssertFalse(summary.contains(sha) || summary.contains("github.com") || summary.contains("sources.packages"), summary)

        let technical = presentation.technical
        XCTAssertEqual(technical.map(\.title), ["Package \(source)", "Configured source"])
        for (item, section) in zip(package.items, technical) {
            XCTAssertEqual(section.facts.first { $0.title == "Before" }?.value, item.before)
            XCTAssertEqual(section.facts.first { $0.title == "After" }?.value, item.after)
            XCTAssertEqual(section.exact, item.exact)
        }
        XCTAssertEqual(technical[0].facts.first { $0.title == "Scope" }?.value, "\(source)\nUser package (global)")
        XCTAssertEqual(technical[1].facts.first { $0.title == "Scope" }?.value, "sources.packages (global) pin")
        XCTAssertEqual(presentation.change.map(\.value), ["Update \(source) to commit \(sha)", String(repeating: "d", count: 64)])

        let confirm = "Adding or enabling a server, or changing its command or address, runs it on this Mac."
        let mcp = try review(title: "MCP server", items: [
            .object(["label": .string("MCP server"), "before": .string("Not set"), "after": .string("npx -y qaf-mcp"),
                     "detail": .string("Global stored value\nglobal\n\(confirm)"),
                     "exact": .string("{\"target\":{\"kind\":\"global\"},\"key\":\"tools.mcp.server\",\"layer\":\"global\",\"qualifiers\":{\"server\":\"qaf\"},\"op\":\"set\",\"before\":null,\"after\":{\"command\":\"npx\"}}")]),
        ])
        let added = ChangeReviewPresentation(mcp)
        XCTAssertEqual(added.title, "Add qaf MCP server")
        XCTAssertEqual(added.items.map(\.note), [confirm])
        XCTAssertEqual(added.technical[0].facts.first { $0.title == "Scope" }?.value, "Global stored value\nglobal")

        let near = "b29af0f000000000000000000000000000000000"
        let collision = ChangeReviewPresentation(try review(title: "Pin", items: [
            .object(["label": .string("Pin"), "before": .string(sha), "after": .string(near)]),
        ]))
        XCTAssertEqual(collision.items.map(\.before), [sha])
        XCTAssertEqual(collision.items.map(\.after), [near])
    }

    func testAutomationDetailKeepsIdentifiersInTechnicalDetailsAndThePromptAsABlock() throws {
        let record = try AutomationPresentationFixture.record(activation: "enabled", workspace: true)
        let sections = AutomationFactSection.detail(record: record, server: "Mac", targetLabel: "New session per run · project")
        let prompt = try XCTUnwrap(sections.first { $0.title == "Prompt" })
        XCTAssertEqual(prompt.facts.map(\.isBlock), [true])
        XCTAssertEqual(prompt.facts.first?.value, record.action.content)
        let main = sections.flatMap(\.facts).map { "\($0.title)=\($0.value)" }.joined(separator: "\n")
        for hidden in [record.id, "Revision", "Created", "Updated", "/workspace/project"] {
            XCTAssertFalse(main.contains(hidden), "\(hidden) belongs in technical details\n\(main)")
        }
        let technical = AutomationFactSection.technical(record: record)
        XCTAssertEqual(technical.first { $0.title == "Automation ID" }?.value, record.id)
        XCTAssertEqual(technical.first { $0.title == "Revision" }?.value, "\(record.revision)")
        XCTAssertEqual(technical.first { $0.title == "Workspace" }?.value, "/workspace/project")
        XCTAssertNotNil(technical.first { $0.title == "Created" })
        XCTAssertNotNil(technical.first { $0.title == "Created by" })
    }
}
