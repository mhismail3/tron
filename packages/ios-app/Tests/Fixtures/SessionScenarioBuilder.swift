import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import TronMobile

struct SessionScenarioBuilder: Sendable {
    enum ScenarioError: Error { case targetTooSmall, imageEncodingFailed }

    struct PagedSession: Sendable {
        let seed: Int
        let totalEntries: Int

        func page(before: Int, count: Int, overlap: Int = 0, gap: Int = 0) -> [TranscriptItem] {
            precondition(count >= 0 && overlap >= 0 && gap >= 0)
            let end = min(totalEntries, max(0, before + overlap - gap))
            let start = max(0, end - count)
            return (start..<end).map { SessionScenarioBuilder.item(seed: seed, index: $0) }
        }
    }

    struct MarkdownUpdate: Hashable, Sendable {
        let index: Int
        let text: String
        let elapsed: Duration
    }

    struct SyntheticAttachment: Hashable, Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        let encodedData: Data
        let content: ContentPart
    }

    struct GeneratedImageFixture: Hashable, Sendable {
        enum Format: String, CaseIterable, Sendable { case jpeg, png }
        enum Orientation: UInt32, Sendable { case up = 1, right = 6 }

        let seed: Int
        let format: Format
        let pixelWidth: Int
        let pixelHeight: Int
        let orientation: Orientation
        let encodedData: Data
        let content: ContentPart

        func rgbaPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            precondition((0..<pixelWidth).contains(x) && (0..<pixelHeight).contains(y))
            return SessionScenarioBuilder.rgbaPixel(seed: seed, x: x, y: y)
        }
    }

    let seed: Int

    func openingTail(targetEncodedBytes: Int) throws -> SessionSnapshot {
        var snapshot = Self.snapshot(seed: seed)
        var encodedBytes = try JSONEncoder.gateway.encode(snapshot).count
        guard targetEncodedBytes >= encodedBytes else { throw ScenarioError.targetTooSmall }
        var index = 0

        while true {
            let separatorBytes = snapshot.transcript.isEmpty ? 0 : 1
            let empty = Self.message(seed: seed, index: index, textBytes: 0)
            let fixedBytes = try JSONEncoder.gateway.encode(empty).count + separatorBytes
            guard encodedBytes + fixedBytes <= targetEncodedBytes else { break }

            let textBytes = min(4_096, targetEncodedBytes - encodedBytes - fixedBytes)
            snapshot.transcript.append(Self.message(seed: seed, index: index, textBytes: textBytes))
            encodedBytes += fixedBytes + textBytes
            index += 1
        }

        return snapshot
    }

    func pagedMixedSession(totalEntries: Int = 10_000) -> PagedSession {
        precondition(totalEntries >= 0)
        return PagedSession(seed: seed, totalEntries: totalEntries)
    }

    func historyPage(count: Int, longRowBytes: Int) -> [TranscriptItem] {
        precondition(count >= 0 && longRowBytes >= 0)
        return (0..<count).map { Self.item(seed: seed, index: $0, textBytes: longRowBytes) }
    }

    func liveToolBurst(count: Int) -> [ToolExecutionState] {
        precondition((100...256).contains(count))
        return (0..<count).map { index in
            ToolExecutionState(
                toolCallId: Self.id(seed: seed, index: index, suffix: "tool"),
                toolName: ["read", "bash", "find", "subagent"][index % 4],
                order: index,
                status: .running,
                arguments: .object(["index": .number(Double(index))]),
                partialResult: .object(["progress": .number(Double(index + 1) / Double(count))]),
                result: nil,
                output: "progress-\(seed)-\(index)",
                isError: false,
                startedAt: Self.timestamp,
                updatedAt: Self.timestamp,
                lastProgressAt: Self.timestamp,
                progressSequence: index + 1
            )
        }
    }

    func markdownStream(updateCount: Int, rate: Int) -> [MarkdownUpdate] {
        precondition(updateCount >= 0 && (rate == 30 || rate == 60))
        let adversarialChunks = [
            "# Heading-\(seed)",
            " 🧑🏽‍💻e\u{301}",
            "\n\n---",
            "\n\nInline *",
            "open",
            "* and [link",
            "](https://example.invalid)",
            "\n\n```swift",
            "\nlet value = \"🙂\"",
            "\n```",
            "\n\nname | value",
            "\n--- | :---:",
            "\nrow | one",
            "\n\n- first",
            "\n  2. nested",
            "\n\n> quoted",
            "\n> continuation",
            "\n\n## Tail heading",
            "\n\n___",
        ]
        var cumulative = ""
        return (0..<updateCount).map { index in
            if index < adversarialChunks.count {
                cumulative += adversarialChunks[index]
            } else {
                cumulative += " tail-\(seed)-\(index)"
            }
            return MarkdownUpdate(
                index: index,
                text: cumulative,
                elapsed: .nanoseconds(Int64(index) * 1_000_000_000 / Int64(rate))
            )
        }
    }

    func generatedImageFixture(
        format: GeneratedImageFixture.Format,
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: GeneratedImageFixture.Orientation
    ) throws -> GeneratedImageFixture {
        precondition(pixelWidth > 0 && pixelHeight > 0)
        var pixels = [UInt8]()
        pixels.reserveCapacity(pixelWidth * pixelHeight * 4)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let pixel = Self.rgbaPixel(seed: seed, x: x, y: y)
                pixels.append(contentsOf: [pixel.0, pixel.1, pixel.2, pixel.3])
            }
        }
        let pixelData = Data(pixels)
        guard let provider = CGDataProvider(data: pixelData as CFData),
              let image = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ScenarioError.imageEncodingFailed
        }

        let data = NSMutableData()
        let type = format == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ScenarioError.imageEncodingFailed
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScenarioError.imageEncodingFailed
        }

        let mimeType = format == .jpeg ? "image/jpeg" : "image/png"
        let fileExtension = format == .jpeg ? "jpg" : "png"
        let encodedData = data as Data
        return GeneratedImageFixture(
            seed: seed,
            format: format,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: orientation,
            encodedData: encodedData,
            content: ContentPart(
                id: "generated-image-\(seed)-\(format.rawValue)",
                type: .image,
                text: nil,
                attachment: .init(
                    name: "generated-\(seed).\(fileExtension)",
                    mimeType: mimeType,
                    size: encodedData.count
                ),
                redacted: nil,
                mimeType: mimeType,
                blobId: "generated-image-blob-\(seed)-\(format.rawValue)",
                toolCallId: nil,
                name: nil,
                arguments: nil
            )
        )
    }

    func highResolutionAttachment(pixelWidth: Int, pixelHeight: Int, encodedBytes: Int) -> SyntheticAttachment {
        precondition(pixelWidth > 0 && pixelHeight > 0 && encodedBytes >= 0)
        let name = "synthetic-\(seed).jpg"
        return SyntheticAttachment(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            encodedData: Data(repeating: UInt8(truncatingIfNeeded: seed), count: encodedBytes),
            content: ContentPart(
                id: "attachment-\(seed)",
                type: .image,
                text: nil,
                attachment: .init(name: name, mimeType: "image/jpeg", size: encodedBytes),
                redacted: nil,
                mimeType: "image/jpeg",
                blobId: "synthetic-blob-\(seed)",
                toolCallId: nil,
                name: nil,
                arguments: nil
            )
        )
    }

    private static let timestamp = "2026-01-01T00:00:00Z"

    private static func rgbaPixel(seed: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(truncatingIfNeeded: seed &* 17 &+ x &* 31 &+ y &* 7),
            UInt8(truncatingIfNeeded: seed &* 29 &+ x &* 11 &+ y &* 37),
            UInt8(truncatingIfNeeded: seed &* 43 &+ x &* 19 &+ y &* 13),
            255
        )
    }

    private static func snapshot(seed: Int) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: "scenario-\(seed)",
            runtimeGeneration: "runtime-\(seed)",
            revision: 1,
            eventSequence: 1,
            phase: .idle,
            name: "Synthetic scenario",
            cwd: "/workspace",
            parentSessionId: nil,
            model: ModelRef(provider: "test", id: "synthetic"),
            thinkingLevel: "medium",
            availableThinkingLevels: ["off", "medium"],
            contextUsage: nil,
            stats: SessionStats(
                userMessages: 0,
                assistantMessages: 0,
                toolCalls: 0,
                toolResults: 0,
                totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0),
                latestCacheHitRate: nil,
                cost: 0
            ),
            queued: .init(steering: [], followUp: []),
            transcript: [],
            transcriptStart: nil,
            transcriptTotal: nil,
            streaming: nil,
            leafEntryId: nil,
            operation: nil,
            retry: nil,
            toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(
                version: 2,
                hostEpoch: "test-host",
                revision: 0,
                capabilities: [],
                diagnostics: [],
                semanticState: .init(
                    statuses: [:], working: .init(message: nil, visible: false),
                    hiddenThinkingLabel: nil, widgets: [], title: nil,
                    toolsExpanded: false, editorRevision: 0, editorText: ""
                ),
                surfaces: [], pendingInteractions: [], inputLease: nil, projection: nil
            ),
            diagnostics: []
        )
    }

    private static func item(seed: Int, index: Int, textBytes: Int = 48) -> TranscriptItem {
        switch index % 5 {
        case 0: return message(seed: seed, index: index, role: .user, textBytes: textBytes)
        case 1: return message(seed: seed, index: index, role: .assistant, textBytes: textBytes)
        case 2: return toolResult(seed: seed, index: index, textBytes: textBytes)
        case 3:
            return .bash(BashTranscriptItem(
                id: id(seed: seed, index: index),
                parentId: index == 0 ? nil : id(seed: seed, index: index - 1),
                timestamp: timestamp,
                kind: .bash,
                command: "printf scenario-\(seed)-\(index)",
                output: String(repeating: "b", count: textBytes),
                exitCode: 0,
                cancelled: false,
                truncated: false,
                fullOutputPath: nil,
                excludeFromContext: nil
            ))
        default:
            return .summary(SummaryTranscriptItem(
                id: id(seed: seed, index: index),
                parentId: id(seed: seed, index: index - 1),
                timestamp: timestamp,
                kind: .compaction,
                summary: String(repeating: "s", count: textBytes),
                tokensBefore: index * 10,
                details: nil,
                usage: nil,
                fromHook: false
            ))
        }
    }

    private static func message(
        seed: Int,
        index: Int,
        role: TranscriptItem.Role = .assistant,
        textBytes: Int
    ) -> TranscriptItem {
        .message(MessageTranscriptItem(
            id: id(seed: seed, index: index),
            parentId: index == 0 ? nil : id(seed: seed, index: index - 1),
            timestamp: timestamp,
            kind: .message,
            role: role,
            content: [ContentPart(
                id: id(seed: seed, index: index, suffix: "text"),
                type: .text,
                text: String(repeating: "x", count: textBytes),
                attachment: nil,
                redacted: nil,
                mimeType: nil,
                blobId: nil,
                toolCallId: nil,
                name: nil,
                arguments: nil
            )],
            provider: role == .assistant ? "test" : nil,
            modelId: role == .assistant ? "synthetic" : nil,
            stopReason: role == .assistant ? "stop" : nil,
            errorMessage: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            details: nil,
            usage: nil,
            startedAt: nil,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil
        ))
    }

    private static func toolResult(seed: Int, index: Int, textBytes: Int) -> TranscriptItem {
        .message(MessageTranscriptItem(
            id: id(seed: seed, index: index),
            parentId: id(seed: seed, index: index - 1),
            timestamp: timestamp,
            kind: .message,
            role: .toolResult,
            content: [ContentPart(
                id: id(seed: seed, index: index, suffix: "result"),
                type: .text,
                text: String(repeating: "r", count: textBytes),
                attachment: nil,
                redacted: nil,
                mimeType: nil,
                blobId: nil,
                toolCallId: nil,
                name: nil,
                arguments: nil
            )],
            provider: nil,
            modelId: nil,
            stopReason: nil,
            errorMessage: nil,
            toolCallId: id(seed: seed, index: index, suffix: "call"),
            toolName: "read",
            isError: false,
            details: nil,
            usage: nil,
            startedAt: timestamp,
            completedAt: timestamp,
            durationMs: 1,
            lastProgressAt: nil,
            progressSequence: nil
        ))
    }

    private static func id(seed: Int, index: Int, suffix: String? = nil) -> String {
        let base = String(format: "scenario-%08x-%08d", seed, index)
        return suffix.map { "\(base)-\($0)" } ?? base
    }
}
