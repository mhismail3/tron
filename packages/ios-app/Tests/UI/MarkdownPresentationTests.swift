import Foundation
import Testing
@testable import TronMobile

@Suite("Pure Markdown presentation")
struct MarkdownPresentationTests {
    @Test("cold parser preserves exact block kinds, values, UTF-8 ranges, and source identities")
    func exactDocument() throws {
        let source = "  # Heading  \n\n> quote \n> next\n\n- one\n  2. two\n\n``` swift \n code  \n```\n\n| a | b |\n| - | :- |\n| c | d |\n\n***"
        let document = MarkdownPresentation.Document(source: source)
        requireSendable(document)

        #expect(document.blocks.count == 6)
        #expect(document.blocks.map(\.sourceRange) == [
            .init(lowerBound: 0, upperBound: 13),
            .init(lowerBound: 15, upperBound: 30),
            .init(lowerBound: 32, upperBound: 46),
            .init(lowerBound: 48, upperBound: 70),
            .init(lowerBound: 72, upperBound: 102),
            .init(lowerBound: 104, upperBound: 107),
        ])
        #expect(document.blocks.map(\.id.sourceRange) == document.blocks.map(\.sourceRange))
        #expect(document.blocks.map(\.id.content) == [
            "  # Heading  ",
            "> quote \n> next",
            "- one\n  2. two",
            "``` swift \n code  \n```",
            "| a | b |\n| - | :- |\n| c | d |",
            "***",
        ])

        guard case .heading(level: 1, inline: let heading) = document.blocks[0].kind,
              case .quote(let quote) = document.blocks[1].kind,
              case .list(let items) = document.blocks[2].kind,
              case .code(language: "swift", code: let code) = document.blocks[3].kind,
              case .table(let rows) = document.blocks[4].kind,
              case .rule = document.blocks[5].kind else {
            Issue.record("representative document block classification changed")
            return
        }
        #expect(heading.source == "Heading")
        #expect(quote.source == "quote\nnext")
        #expect(items.map(\.sourceRange) == [
            .init(lowerBound: 32, upperBound: 37),
            .init(lowerBound: 38, upperBound: 46),
        ])
        #expect(items.map(\.id.content) == ["- one", "  2. two"])
        #expect(items.map(\.depth) == [0, 1])
        #expect(items.map(\.marker) == ["•", "2."])
        #expect(items.map(\.inline.source) == ["one", "two"])
        #expect(code == " code  ")
        #expect(!document.blocks[3].isOpenCodeFence)
        #expect(rows == [["a", "b"], ["c", "d"]])
    }

    @Test("equal duplicate blocks and list items remain distinct by exact source range")
    func duplicateIdentity() throws {
        let paragraphs = MarkdownPresentation.Document(source: "same\n\nsame")
        #expect(paragraphs.blocks.count == 2)
        #expect(paragraphs.blocks[0].id.content == paragraphs.blocks[1].id.content)
        #expect(paragraphs.blocks[0].id != paragraphs.blocks[1].id)
        #expect(paragraphs.blocks.map(\.sourceRange) == [
            .init(lowerBound: 0, upperBound: 4),
            .init(lowerBound: 6, upperBound: 10),
        ])

        let list = MarkdownPresentation.Document(source: "- same\n- same")
        guard case .list(let items) = try #require(list.blocks.first).kind else {
            Issue.record("duplicate list fixture was not a list")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].inline.source == items[1].inline.source)
        #expect(items[0].id != items[1].id)
    }

    @Test("identity retains only exact blocks and resets subtree state across code, table, and list revisions")
    func subtreeStateIdentityPolicy() throws {
        let code = try #require(MarkdownPresentation.Document(source: "```\na\n```").blocks.first)
        let sameCode = try #require(MarkdownPresentation.Document(source: "```\na\n```").blocks.first)
        let changedCode = try #require(MarkdownPresentation.Document(source: "```\nb\n```").blocks.first)
        #expect(code.id == sameCode.id)
        #expect(code.sourceRange == changedCode.sourceRange)
        #expect(code.id != changedCode.id)

        let table = try #require(MarkdownPresentation.Document(source: "a|b\n-|-\nc|d").blocks.first)
        let sameTable = try #require(MarkdownPresentation.Document(source: "a|b\n-|-\nc|d").blocks.first)
        let changedTable = try #require(MarkdownPresentation.Document(source: "a|b\n-|-\ne|f").blocks.first)
        #expect(table.id == sameTable.id)
        #expect(table.sourceRange == changedTable.sourceRange)
        #expect(table.id != changedTable.id)

        let list = try #require(MarkdownPresentation.Document(source: "- alpha\n- beta!").blocks.first)
        let sameList = try #require(MarkdownPresentation.Document(source: "- alpha\n- beta!").blocks.first)
        let changedList = try #require(MarkdownPresentation.Document(source: "- bravo\n- beta!").blocks.first)
        guard case .list(let items) = list.kind,
              case .list(let sameItems) = sameList.kind,
              case .list(let changedItems) = changedList.kind else {
            Issue.record("identity-policy list fixtures were not lists")
            return
        }
        #expect(list.id == sameList.id)
        #expect(items.map(\.id) == sameItems.map(\.id))
        #expect(list.sourceRange == changedList.sourceRange)
        #expect(list.id != changedList.id)
        #expect(items[0].sourceRange == changedItems[0].sourceRange)
        #expect(items[0].id != changedItems[0].id)
        #expect(items[1].id == changedItems[1].id)

        let sameRangeTypeChange = try #require(
            MarkdownPresentation.Document(source: "```````````````").blocks.first
        )
        guard case .code = sameRangeTypeChange.kind else {
            Issue.record("same-range type-change fixture was not code")
            return
        }
        #expect(sameRangeTypeChange.sourceRange == list.sourceRange)
        #expect(sameRangeTypeChange.id != list.id)
    }

    @Test("incomplete and malformed syntax retains the established permissive classifications")
    func incompleteAndMalformedSyntax() throws {
        let source = "####### nope\n1.no\n01. yes\n\n>   x  \n\n  ``` lang  \nunterminated"
        let document = MarkdownPresentation.Document(source: source)
        #expect(document.blocks.count == 4)

        guard case .paragraph(let paragraph) = document.blocks[0].kind,
              case .list(let items) = document.blocks[1].kind,
              case .quote(let quote) = document.blocks[2].kind,
              case .code(language: "lang", code: "unterminated") = document.blocks[3].kind else {
            Issue.record("malformed/incomplete syntax classification changed")
            return
        }
        #expect(paragraph.source == "####### nope\n1.no")
        #expect(items.map(\.marker) == ["01."])
        #expect(items.map(\.inline.source) == ["yes"])
        #expect(quote.source == "x")
        #expect(document.blocks[3].isOpenCodeFence)

        let incompleteInline = MarkdownPresentation.Document(source: "*open [link]( and `code")
        guard case .paragraph(let inline) = try #require(incompleteInline.blocks.first).kind else {
            Issue.record("incomplete inline source was not retained as a paragraph")
            return
        }
        #expect(inline.source == "*open [link]( and `code")
        #expect(inline.accessibilitySource == inline.source)
    }

    @Test("tables retain raw Text cells, escaped-pipe splitting, and paragraph promotion quirks")
    func tableQuirks() throws {
        let escaped = MarkdownPresentation.Document(source: "a\\|b | c\n---|---|---\nx\\|y | z")
        guard case .table(let rows) = try #require(escaped.blocks.first).kind else {
            Issue.record("escaped-pipe fixture was not promoted to a table")
            return
        }
        #expect(rows == [["a\\", "b", "c"], ["x\\", "y", "z"]])

        let absorbed = MarkdownPresentation.Document(source: "intro\nh|v\n-|-")
        guard case .paragraph(let paragraph) = try #require(absorbed.blocks.first).kind else {
            Issue.record("mid-paragraph table candidate no longer follows the cold-parser quirk")
            return
        }
        #expect(absorbed.blocks.count == 1)
        #expect(paragraph.source == "intro\nh|v\n-|-")
    }

    @Test("UTF-8 ranges use byte boundaries without changing Unicode source")
    func unicodeByteRanges() throws {
        let source = "🙂 paragraph\n\n> café\n- e\u{301}"
        let document = MarkdownPresentation.Document(source: source)
        #expect(document.blocks.map(\.sourceRange) == [
            .init(lowerBound: 0, upperBound: 14),
            .init(lowerBound: 16, upperBound: 23),
            .init(lowerBound: 24, upperBound: 29),
        ])
        #expect(document.blocks.map(\.id.content) == ["🙂 paragraph", "> café", "- e\u{301}"])

        guard case .paragraph(let paragraph) = document.blocks[0].kind,
              case .quote(let quote) = document.blocks[1].kind,
              case .list(let items) = document.blocks[2].kind else {
            Issue.record("Unicode fixture classification changed")
            return
        }
        #expect(paragraph.source == "🙂 paragraph")
        #expect(quote.source == "café")
        #expect(items[0].inline.source == "e\u{301}")
    }

    @Test("inline attribution is constructed by the cold model with exact fallback and accessibility source")
    func attributedEquivalence() throws {
        let values = [
            "plain  whitespace",
            "**bold** and _emphasis_",
            "*unmatched",
            "[incomplete](",
            "`open code",
            "null \u{0} scalar",
        ]
        for value in values {
            let document = MarkdownPresentation.Document(source: value)
            guard case .paragraph(let inline) = try #require(document.blocks.first).kind else {
                Issue.record("inline equivalence fixture was not a paragraph")
                continue
            }
            let oracle = try? AttributedString(
                markdown: value,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            #expect(inline.attributedString == oracle)
            #expect(inline.source == value)
            #expect(inline.accessibilitySource == value)
        }
    }

    @Test("only an unterminated code fence is eligible for streaming progress")
    func codeFenceSettlement() throws {
        let document = MarkdownPresentation.Document(source: "```swift\nclosed\n```\n\ntext\n\n```json\nopen")
        let codeBlocks = document.blocks.filter { block in
            if case .code = block.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 2)
        #expect(!codeBlocks[0].isOpenCodeFence)
        #expect(codeBlocks[1].isOpenCodeFence)
    }

    @Test("renderer accepts the exact parsed document and convenience initialization delegates to the cold oracle")
    @MainActor
    func rendererUsesDocument() {
        let source = "# Heading\n\nparagraph\n\n| raw | cells |\n| --- | --- |"
        let document = MarkdownPresentation.Document(source: source)
        let supplied = TronMarkdownView(document: document, streaming: true)
        let convenience = TronMarkdownView(text: source, streaming: true)

        #expect(supplied.document == document)
        #expect(convenience.document == document)
        #expect(supplied.streaming)
        #expect(convenience.streaming)
    }

    private func requireSendable<T: Sendable>(_: T) {}
}
