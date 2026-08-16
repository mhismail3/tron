import Foundation
import ImageIO
import Testing
@testable import TronMobile

@Suite("Generated session scenarios")
struct SessionScenarioBuilderTests {
    @Test("opening tail is deterministic and fills the requested byte budget without exceeding it")
    func boundedOpeningTail() throws {
        let builder = SessionScenarioBuilder(seed: 42)

        let first = try builder.openingTail(targetEncodedBytes: 800_000)
        let deterministic = try builder.openingTail(targetEncodedBytes: 32_000)
        let repeated = try builder.openingTail(targetEncodedBytes: 32_000)
        let firstData = try JSONEncoder.gateway.encode(first)

        #expect(deterministic == repeated)
        #expect(firstData.count == 800_000)
        #expect(!first.transcript.isEmpty)
        #expect(Set(first.transcript.map(\.id)).count == first.transcript.count)
        let text = String(decoding: firstData, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/private/"))
    }

    @Test("opening tail rejects a budget smaller than its empty snapshot")
    func undersizedOpeningTail() {
        #expect(throws: SessionScenarioBuilder.ScenarioError.self) {
            try SessionScenarioBuilder(seed: 42).openingTail(targetEncodedBytes: 0)
        }
    }

    @Test("paged mixed sessions generate only the requested range with explicit overlap and gap")
    func onDemandPages() {
        let scenario = SessionScenarioBuilder(seed: 42).pagedMixedSession()

        let baseline = scenario.page(before: 100, count: 10)
        let overlap = scenario.page(before: 100, count: 10, overlap: 2)
        let gap = scenario.page(before: 100, count: 10, gap: 2)

        #expect(scenario.totalEntries == 10_000)
        #expect(baseline.map(\.id) == (90..<100).map(id))
        #expect(overlap.map(\.id) == (92..<102).map(id))
        #expect(gap.map(\.id) == (88..<98).map(id))
        #expect(baseline.map(\.kind) == [
            .message, .message, .message, .bash, .compaction,
            .message, .message, .message, .bash, .compaction,
        ])
        #expect(baseline.map(\.role) == [
            .user, .assistant, .toolResult, nil, nil,
            .user, .assistant, .toolResult, nil, nil,
        ])
    }

    @Test("history pages have exact counts, deterministic IDs, and requested long-row payloads")
    func longHistoryPage() {
        let builder = SessionScenarioBuilder(seed: 7)

        let first = builder.historyPage(count: 64, longRowBytes: 8_192)
        let second = builder.historyPage(count: 64, longRowBytes: 8_192)

        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.text.utf8.count == 8_192 })
        #expect(Set(first.map(\.id)).count == 64)
    }

    @Test("tool bursts cover the supported stress range", arguments: [100, 256])
    func toolBursts(count: Int) {
        let tools = SessionScenarioBuilder(seed: 9).liveToolBurst(count: count)

        #expect(tools.count == count)
        #expect(tools.map(\.order) == (0..<count).map(Optional.some))
        #expect(tools.map(\.progressSequence) == (1...count).map(Optional.some))
        #expect(Set(tools.map(\.id)).count == count)
        #expect(tools.allSatisfy { $0.status == .running && !$0.isError })
    }

    @Test("markdown streams expose true prefix-cumulative adversarial updates at 30 and 60 hertz")
    func markdownRates() throws {
        let builder = SessionScenarioBuilder(seed: 11)
        let thirty = builder.markdownStream(updateCount: 90, rate: 30)
        let sixty = builder.markdownStream(updateCount: 90, rate: 60)

        #expect(thirty.map(\.text) == sixty.map(\.text))
        #expect(thirty.last?.elapsed == .nanoseconds(2_966_666_666))
        #expect(sixty.last?.elapsed == .nanoseconds(1_483_333_333))
        #expect(zip(thirty, thirty.dropFirst()).allSatisfy { previous, next in
            next.text.hasPrefix(previous.text) && next.text.utf8.count > previous.text.utf8.count
        })
        #expect(thirty[1].text.contains("🧑🏽‍💻e\u{301}"))

        let unmatchedInline = MarkdownPresentation.Document(source: thirty[3].text)
        let closedInline = MarkdownPresentation.Document(source: thirty[5].text)
        let openFence = MarkdownPresentation.Document(source: thirty[7].text)
        let closedFence = MarkdownPresentation.Document(source: thirty[9].text)
        let tableHeaderOnly = MarkdownPresentation.Document(source: thirty[10].text)
        let promotedTable = MarkdownPresentation.Document(source: thirty[11].text)
        let list = MarkdownPresentation.Document(source: thirty[14].text)
        let quote = MarkdownPresentation.Document(source: thirty[16].text)
        let final = MarkdownPresentation.Document(source: thirty[18].text)

        guard case .paragraph(let unmatched) = unmatchedInline.blocks.last?.kind,
              case .paragraph(let closed) = closedInline.blocks.last?.kind,
              case .code(language: "swift", code: let openCode) = openFence.blocks.last?.kind,
              case .code(language: "swift", code: let closedCode) = closedFence.blocks.last?.kind,
              case .paragraph = tableHeaderOnly.blocks.last?.kind,
              case .table = promotedTable.blocks.last?.kind,
              case .list = list.blocks.last?.kind,
              case .quote = quote.blocks.last?.kind,
              case .rule = final.blocks.last?.kind else {
            Issue.record("adversarial cumulative transitions did not reach their characterized block kinds")
            return
        }
        #expect(unmatched.source == "Inline *")
        #expect(closed.source == "Inline *open* and [link")
        #expect(openCode == "")
        #expect(closedCode == "let value = \"🙂\"")
    }

    @Test("generated JPEG and PNG fixtures are valid, oriented, and deterministic")
    func generatedImages() throws {
        let builder = SessionScenarioBuilder(seed: 13)

        for format in SessionScenarioBuilder.GeneratedImageFixture.Format.allCases {
            let first = try builder.generatedImageFixture(
                format: format,
                pixelWidth: 17,
                pixelHeight: 11,
                orientation: .right
            )
            let repeated = try builder.generatedImageFixture(
                format: format,
                pixelWidth: 17,
                pixelHeight: 11,
                orientation: .right
            )
            let source = try #require(CGImageSourceCreateWithData(first.encodedData as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

            #expect(first == repeated)
            #expect(first.pixelWidth == 17)
            #expect(first.pixelHeight == 11)
            #expect(first.orientation == .right)
            #expect(decoded.width == 17)
            #expect(decoded.height == 11)
            #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == 6)
            #expect(first.content.attachment?.size == first.encodedData.count)
            #expect(first.content.mimeType == (format == .jpeg ? "image/jpeg" : "image/png"))
            #expect(first.rgbaPixel(x: 0, y: 0) == (221, 121, 47, 255))
            #expect(first.rgbaPixel(x: 16, y: 10) == (19, 155, 225, 255))
        }
    }

    @Test("high-resolution attachments use synthetic metadata and exact bounded bytes")
    func syntheticAttachment() {
        let attachment = SessionScenarioBuilder(seed: 13).highResolutionAttachment(
            pixelWidth: 8_192,
            pixelHeight: 6_144,
            encodedBytes: 2_000_000
        )

        #expect(attachment.pixelWidth == 8_192)
        #expect(attachment.pixelHeight == 6_144)
        #expect(attachment.encodedData.count == 2_000_000)
        #expect(attachment.content.attachment?.name == "synthetic-13.jpg")
        #expect(attachment.content.attachment?.size == 2_000_000)
        #expect(attachment.content.blobId == "synthetic-blob-13")
    }

    private func id(_ index: Int) -> String {
        String(format: "scenario-%08x-%08d", 42, index)
    }
}
