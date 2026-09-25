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
        #expect(quote.source == "quote \nnext")
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
        #expect(rows.map { $0.map(\.source) } == [["a", "b"], ["c", "d"]])
    }

    @Test("reflows Markdown soft wraps only in presentation and preserves exact source")
    func markdownSoftWrapsReflowWithoutLosingExplicitBreaks() throws {
        let lines = [
            "A README paragraph is hard-wrapped",
            "for source readability and contains `inline code`.",
            "",
            "A second paragraph",
            "continues naturally.",
            "Explicit hard break  ",
            "remains a break.",
            "Backslash break\\",
            "after the escape.",
        ]
        let source = lines.joined(separator: "\n")
        let document = MarkdownPresentation.Document(source: source)
        #expect(document.source == source)
        #expect(document.blocks.first?.id.content == "A README paragraph is hard-wrapped\nfor source readability and contains `inline code`.")
        guard case .paragraph(let prose) = document.blocks.first?.kind else {
            Issue.record("Expected a reflowed paragraph")
            return
        }
        let attributed = try #require(prose.attributedString)
        #expect(prose.source == "A README paragraph is hard-wrapped\nfor source readability and contains `inline code`.")
        #expect(String(attributed.characters) == "A README paragraph is hard-wrapped for source readability and contains inline code.")
        #expect(prose.accessibilitySource == prose.source)

        let hardBreaks = ["ordinary wrap", "continues", "", "new paragraph", "line  ", "hard break", "slash\\", "next"].joined(separator: "\n")
        #expect(MarkdownPresentation.reflowSoftLineBreaks(hardBreaks) == "ordinary wrap continues\n\nnew paragraph line  \nhard break slash\\\nnext")
        // Known-bad control: the old inlineOnlyPreservingWhitespace request source
        // retains the hard-wrap newline that previously rendered as a premature line break.
        let oldBehavior = try AttributedString(markdown: lines.prefix(2).joined(separator: "\n"), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(String(oldBehavior.characters).contains("hard-wrapped\nfor source"))
        #expect(!String(attributed.characters).contains("hard-wrapped\nfor source"))
    }

    @Test("soft wraps reflow across quotes and list continuations while code remains literal")
    func wrapsAcrossMarkdownBlocks() throws {
        let source = [
            "> This quoted sentence is hard-wrapped", "> and must read continuously.", "",
            "- A list item has", "  a source continuation.", "",
            "```text", "keep", "these", "code lines", "```",
        ].joined(separator: "\n")
        let document = MarkdownPresentation.Document(source: source)
        guard case .quote(let quote) = document.blocks[0].kind,
              case .list(let items) = document.blocks[1].kind,
              case .code(language: "text", code: let code) = document.blocks[2].kind else {
            Issue.record("Expected quote, list, and fenced code blocks")
            return
        }
        #expect(String(try #require(quote.attributedString).characters) == "This quoted sentence is hard-wrapped and must read continuously.")
        #expect(items.map(\.inline.source) == ["A list item has\na source continuation."])
        #expect(code == "keep\nthese\ncode lines")
        #expect(document.source == source)
    }

    @Test("explicit quoted breaks survive while ordinary quote wraps reflow")
    func quotedHardBreaks() throws {
        let document = MarkdownPresentation.Document(source: "> first  \n> second\\\n> third\n> continued")
        guard case .quote(let quote) = try #require(document.blocks.first).kind else {
            Issue.record("Expected a quote")
            return
        }
        let text = String(try #require(quote.attributedString).characters)
        #expect(text.contains("first"))
        #expect(text.contains("\nsecond"))
        #expect(text.contains("\nthird continued"))
    }

    @Test("tilde and longer backtick fences preserve literal lines and exact closing markers")
    func matchingCodeFences() throws {
        for marker in ["~~~~", "````"] {
            let open = marker + "text\nfirst\n" + String(marker.dropLast()) + "\nsecond"
            let unfinished = try #require(MarkdownPresentation.Document(source: open).blocks.first)
            #expect(unfinished.isOpenCodeFence)
            guard case .code(language: "text", code: let code) = unfinished.kind else {
                Issue.record("Expected literal fenced code")
                continue
            }
            #expect(code == "first\n" + String(marker.dropLast()) + "\nsecond")
            let closed = MarkdownPresentation.Document(source: open + "\n" + marker + "\n\nAfter\ncode.")
            #expect(!closed.blocks[0].isOpenCodeFence)
            #expect(closed.blocks[0].id.content == open + "\n" + marker)
            guard case .paragraph(let paragraph) = closed.blocks[1].kind else {
                Issue.record("Expected prose after closing fence")
                continue
            }
            #expect(String(try #require(paragraph.attributedString).characters) == "After code.")
        }
    }

    @Test("whitespace-only paragraph boundaries, CRLF and escaped backslashes reflow correctly")
    func whitespaceAndEscapes() throws {
        #expect(MarkdownPresentation.reflowSoftLineBreaks("first \n  continued") == "first continued")
        #expect(MarkdownPresentation.reflowSoftLineBreaks("first\r") == "first")
        #expect(MarkdownPresentation.reflowSoftLineBreaks("first\r\nsecond  \r\nthird") == "first second  \nthird")
        #expect(MarkdownPresentation.reflowSoftLineBreaks("first\n \t\nsecond") == "first\n \t\nsecond")
        #expect(MarkdownPresentation.reflowSoftLineBreaks("first\\\\\nsecond") == "first\\\\ second")
        let document = MarkdownPresentation.Document(source: "first\r\ncontinued\r\n\r\nsecond")
        #expect(document.blocks.count == 2)
        #expect(document.source == "first\r\ncontinued\r\n\r\nsecond")
    }

    @Test("nested list continuations keep their item and explicit hard breaks")
    func nestedListContinuation() throws {
        let source = "- Parent\n  - Nested  \n    intentional break\n    continues here"
        guard case .list(let items) = try #require(MarkdownPresentation.Document(source: source).blocks.first).kind else {
            Issue.record("Expected nested list")
            return
        }
        #expect(items.count == 2)
        #expect(items.map(\.depth) == [0, 1])
        let text = String(try #require(items[1].inline.attributedString).characters)
        #expect(text.contains("\nintentional break continues here"))
    }

    @Test("a long wrapped list constructs one item without changing its source identity")
    func longListContinuation() throws {
        let lines = ["- First"] + Array(repeating: "  continuation", count: 500)
        let source = lines.joined(separator: "\n")
        let document = MarkdownPresentation.Document(source: source)
        guard case .list(let items) = try #require(document.blocks.first).kind else {
            Issue.record("Expected one continued list")
            return
        }
        #expect(items.count == 1)
        #expect(items[0].id.content == source)
        let text = String(try #require(items[0].inline.attributedString).characters)
        #expect(text == (["First"] + Array(repeating: "continuation", count: 500)).joined(separator: " "))
    }

    @Test("indented code retains literal source line breaks rather than reflowing prose")
    func indentedCodeRemainsLiteral() throws {
        let source = ["    first code line", "    second code line"].joined(separator: "\n")
        let document = MarkdownPresentation.Document(source: source)
        guard case .code(language: nil, code: let code) = try #require(document.blocks.first?.kind) else {
            Issue.record("Expected an indented code block")
            return
        }
        #expect(code == "first code line\nsecond code line")
        #expect(document.source == source)
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
        #expect(quote.source == "  x  ")
        #expect(document.blocks[3].isOpenCodeFence)

        let incompleteInline = MarkdownPresentation.Document(source: "*open [link]( and `code")
        guard case .paragraph(let inline) = try #require(incompleteInline.blocks.first).kind else {
            Issue.record("incomplete inline source was not retained as a paragraph")
            return
        }
        #expect(inline.source == "*open [link]( and `code")
        #expect(inline.accessibilitySource == inline.source)
    }

    @Test("tables retain exact cell sources, escaped-pipe splitting, and paragraph promotion quirks")
    func tableQuirks() throws {
        let escaped = MarkdownPresentation.Document(source: "a\\|b | c\n---|---|---\nx\\|y | z")
        guard case .table(let rows) = try #require(escaped.blocks.first).kind else {
            Issue.record("escaped-pipe fixture was not promoted to a table")
            return
        }
        #expect(rows.map { $0.map(\.source) } == [["a\\", "b", "c"], ["x\\", "y", "z"]])

        let absorbed = MarkdownPresentation.Document(source: "intro\nh|v\n-|-")
        guard case .paragraph(let paragraph) = try #require(absorbed.blocks.first).kind else {
            Issue.record("mid-paragraph table candidate no longer follows the cold-parser quirk")
            return
        }
        #expect(absorbed.blocks.count == 1)
        #expect(paragraph.source == "intro\nh|v\n-|-")
    }

    @Test("table headers and body cells prepare inline Markdown styling and account for its storage")
    func styledTableCells() throws {
        let source = "| **Header** | *Emphasis* |\n| --- | --- |\n| **bold** and *italic* | ~~removed~~ and `code` |\n| [link](https://example.com) | ***both*** and \\*literal\\* |\n| short |"
        let document = MarkdownPresentation.Document(source: source)
        guard case .table(let rows) = try #require(document.blocks.first).kind else {
            Issue.record("Expected table")
            return
        }
        #expect(rows.count == 4)
        #expect(rows.last?.count == 1)
        #expect(rows[0][0].source == "**Header**")
        let header = try #require(rows[0][0].attributedString)
        #expect(String(header.characters) == "Header")
        #expect(header.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let body = try #require(rows[1][0].attributedString)
        #expect(String(body.characters) == "bold and italic")
        #expect(body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(body.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        let code = try #require(rows[1][1].attributedString)
        #expect(code.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        #expect(code.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let link = try #require(rows[2][0].attributedString)
        #expect(link.runs.first?.link == URL(string: "https://example.com"))
        let nested = try #require(rows[2][1].attributedString)
        #expect(String(nested.characters) == "both and *literal*")
        #expect(nested.runs.contains {
            $0.inlinePresentationIntent?.contains([.stronglyEmphasized, .emphasized]) == true
        })
        #expect(document.blocks[0].kind.accountedByteCount == rows.flatMap { $0 }.reduce(0) { $0 + $1.accountedByteCount })
        #expect(document.source == source)
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
