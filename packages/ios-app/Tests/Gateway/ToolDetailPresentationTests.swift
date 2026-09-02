import Foundation
import Testing
@testable import TronMobile

@Suite("Tool detail semantic presentation")
struct ToolDetailPresentationTests {
    @Test("tool chips wrap with measured row heights and never overlap")
    func chipFlowRows() {
        let frames = ToolChipFlowLayoutPolicy.frames(
            for: [
                CGSize(width: 100, height: 30),
                CGSize(width: 180, height: 42),
                CGSize(width: 120, height: 28),
            ],
            availableWidth: 260,
            spacing: 7
        )
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 100, height: 30),
            CGRect(x: 0, y: 37, width: 180, height: 42),
            CGRect(x: 0, y: 86, width: 120, height: 28),
        ])
        for index in frames.indices {
            for later in frames.indices where later > index {
                #expect(!frames[index].intersects(frames[later]))
            }
        }

        let sanitized = ToolChipFlowLayoutPolicy.frames(
            for: [CGSize(width: CGFloat.infinity, height: CGFloat.nan)],
            availableWidth: 240,
            spacing: 7
        )
        #expect(sanitized == [CGRect(x: 0, y: 0, width: 240, height: 1)])
    }

    @Test("technical payload overview uses bounded top-level summaries")
    func technicalPayloadSummary() {
        #expect(ToolTechnicalPayloadSummary.summary(for: .object(["path": .string("a")])) == "1 top-level field")
        #expect(ToolTechnicalPayloadSummary.summary(for: .object(["path": .string("a"), "line": .number(2)])) == "2 top-level fields")
        #expect(ToolTechnicalPayloadSummary.summary(for: .array([.bool(true)])) == "1 top-level item")
        #expect(ToolTechnicalPayloadSummary.summary(for: .string("value")) == "Scalar protocol value")
    }

    @Test("built-in tools foreground their task-critical request values")
    func builtInSummaries() {
        let fixtures: [(String, JSONValue, ToolDetailKind, String, String)] = [
            ("read", .object(["path": .string("Sources/App.swift")]), .read, "File", "Sources/App.swift"),
            ("write", .object(["path": .string("new.txt"), "content": .string("one\ntwo")]), .write, "File", "new.txt"),
            ("edit", .object(["path": .string("old.txt"), "edits": .array([])]), .edit, "File", "old.txt"),
            ("bash", .object(["command": .string("swift test")]), .bash, "Command", "swift test"),
            ("grep", .object(["pattern": .string("ToolCard")]), .grep, "Pattern", "ToolCard"),
            ("find", .object(["pattern": .string("**/*.swift")]), .find, "Pattern", "**/*.swift"),
            ("ls", .object(["path": .string("Sources")]), .list, "Directory", "Sources"),
        ]

        for fixture in fixtures {
            let presentation = ToolDetailPresentation(tool: tool(fixture.0, request: fixture.1))
            #expect(presentation.kind == fixture.2)
            #expect(presentation.primaryLabel == fixture.3)
            #expect(presentation.primaryValue == fixture.4)
            let expectsTitleIcon = [ToolDetailKind.read, .write, .edit, .bash].contains(fixture.2)
            #expect((presentation.sheetTitleIcon != nil) == expectsTitleIcon)
        }
    }

    @Test("mounted tool detail routes resolve live output and terminal state by stable call ID")
    @MainActor
    func toolDetailRouteResolution() throws {
        let coordinator = PresentationActivityCoordinator()
        let chat = PresentationSurfaceToken(id: "chat", generation: UUID())
        let detail = PresentationSurfaceToken(id: "tool-detail", generation: UUID())
        coordinator.register(chat, parent: nil)
        coordinator.register(detail, parent: chat)
        #expect(coordinator.activity(for: chat) == .presentingDescendant)
        #expect(coordinator.activity(for: chat).allowsDataPublication)

        let original = tool("edit", subtitle: "Running", content: "first")
        let second = tool("bash", subtitle: "Running", content: "other")
        let newest = ChatToolPresentation(
            id: original.id,
            title: original.title,
            subtitle: "Completed",
            request: original.request,
            response: .object(["content": .string("settled")]),
            content: "settled",
            fallbackContent: nil,
            error: false,
            startedAt: original.startedAt,
            completedAt: "2026-01-01T00:00:02Z",
            durationMs: 2_000,
            lastProgressAt: "2026-01-01T00:00:02Z",
            progressSequence: 2
        )
        let route = ToolDetailRoute(toolID: original.id)
        #expect(route.resolve(in: [original])?.content == "first")
        #expect(route.resolve(in: [newest, second])?.content == "settled")
        #expect(route.resolve(in: [newest, second])?.progressSequence == 2)

        let failed = ChatToolPresentation(
            id: original.id,
            title: original.title,
            subtitle: "Failed",
            request: original.request,
            response: .object(["error": .string("failed output")]),
            content: "failed output",
            fallbackContent: nil,
            error: true,
            startedAt: original.startedAt,
            completedAt: "2026-01-01T00:00:03Z",
            durationMs: 3_000,
            lastProgressAt: "2026-01-01T00:00:03Z",
            progressSequence: 3
        )
        #expect(route.resolve(in: [failed, second])?.content == "failed output")
        #expect(route.resolve(in: [failed, second])?.error == true)
        #expect(coordinator.activity(for: chat) == .presentingDescendant)
        #expect(coordinator.activity(for: detail) == .active)
        #expect(coordinator.mountedSurfaceCount == 2)
        #expect(ToolDetailRoute(toolID: "missing").resolve(in: [failed, second]) == nil)
    }

    @Test("status chips combine state and elapsed time with stable semantics")
    func statusChipCopy() throws {
        let completed = tool("edit")
        #expect(ToolStatusChipPresentation.make(tool: completed).text == "Completed · 1.0s")
        #expect(ToolStatusChipPresentation.make(tool: completed).icon == "checkmark.circle.fill")

        let failed = ChatToolPresentation(
            id: "failed", title: "edit", subtitle: "Failed", request: nil, response: nil,
            content: "", fallbackContent: nil, error: true,
            startedAt: "2026-01-01T00:00:00Z", completedAt: "2026-01-01T00:00:01Z",
            durationMs: 1_000, lastProgressAt: nil, progressSequence: nil
        )
        #expect(ToolStatusChipPresentation.make(tool: failed).text == "Failed · 1.0s")
        #expect(ToolStatusChipPresentation.make(tool: failed).icon == "exclamationmark.triangle.fill")

        let running = ChatToolPresentation(
            id: "running", title: "bash", subtitle: "Running",
            request: nil, response: nil, content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:00Z", completedAt: nil,
            durationMs: 1_200,
            durationSampleAnchor: ToolDurationSampleAnchor(uptime: 100),
            lastProgressAt: "2026-01-01T00:00:01.200Z", progressSequence: 1
        )
        let remounted = ChatToolPresentation(descriptor: running.descriptor, payload: running.payload)
        let elapsed = remounted.elapsedMilliseconds(
            at: Date(timeIntervalSince1970: 0),
            uptime: 145
        )
        #expect(elapsed == 46_200)
        #expect(ToolStatusChipPresentation.make(
            tool: remounted,
            elapsedMilliseconds: elapsed
        ).text == "Running · 46.2s")
    }

    @Test("file paths separate restrained directories from accented basenames")
    func filePathPresentation() throws {
        let presentation = ToolDetailPresentation(tool: tool(
            "edit",
            request: .object(["path": .string("packages/ios-app/Sources/App.swift"), "edits": .array([])])
        ))
        let path = try #require(presentation.primaryPath)
        #expect(path.directory == "packages/ios-app/Sources/")
        #expect(path.basename == "App.swift")

        let basenameOnly = ToolPathPresentation.make(ToolTextPreview.make("README.md"))
        #expect(basenameOnly.directory == nil)
        #expect(basenameOnly.basename == "README.md")
    }

    @Test("file aliases and built-in metadata remain concise")
    func metadata() {
        let read = ToolDetailPresentation(tool: tool(
            "read",
            request: .object(["filePath": .string("README.md"), "offset": .number(41), "limit": .number(20)])
        ))
        #expect(read.primaryValue == "README.md")
        #expect(read.metadata.map(\.label) == ["Starts at line", "Maximum lines"])

        let write = ToolDetailPresentation(tool: tool(
            "write",
            request: .object(["path": .string("note.txt"), "content": .string("one\ntwo")])
        ))
        #expect(write.metadata.contains { $0.label == "Lines" && $0.value == "2" })
        #expect(write.metadata.contains { $0.label == "Size" })

        let search = ToolDetailPresentation(tool: tool(
            "grep",
            request: .object([
                "pattern": .string("needle"), "path": .string("Sources"), "glob": .string("*.swift"),
                "ignoreCase": .bool(true), "literal": .bool(false), "context": .number(2), "limit": .number(50),
            ])
        ))
        #expect(search.metadata.map(\.label) == [
            "Location", "File filter", "Ignore case", "Context lines", "Result limit",
        ])
        #expect(search.metadata.map(\.chipText) == [
            "Sources", "*.swift", "Ignore case", "2 context lines", "Up to 50 results",
        ])

        let edit = ToolDetailPresentation(tool: tool(
            "edit",
            request: .object(["path": .string("one.swift"), "edits": .array([
                .object(["oldText": .string("old"), "newText": .string("new")]),
            ])])
        ))
        #expect(edit.metadata.first?.chipText == "1 change")
    }

    @Test("command is complete and output state never falls back to its request")
    func commandAndExplicitEmptyOutput() {
        let command = "set -e\nprintf 'complete command'"
        let running = ToolDetailPresentation(tool: tool(
            "bash",
            subtitle: "Running",
            request: .object(["command": .string(command)]),
            content: "step one\nstep two"
        ))
        #expect(running.primaryValue == command)
        #expect(running.readableResult == "step one\nstep two")

        let empty = ToolDetailPresentation(tool: tool(
            "bash",
            request: .object(["command": .string(command)]),
            content: "",
            fallbackContent: nil
        ))
        #expect(empty.readableResult == nil)
        #expect(empty.structuredResult == nil)
    }

    @Test("live partial output settles to the newest final result and exposes truncation")
    func liveToFinal() {
        let partialTool = tool(
            "bash",
            subtitle: "Running",
            request: .object(["command": .string("build")]),
            response: .object(["content": .string("working")]),
            content: "working",
            outputTruncated: true
        )
        let finalTool = tool(
            "bash",
            request: partialTool.request,
            response: .object(["content": .string("done")]),
            content: "done",
            outputTruncated: false
        )
        #expect(ToolDetailPresentation(tool: partialTool).readableResult == "working")
        #expect(partialTool.outputTruncated)
        #expect(ToolDetailPresentation(tool: finalTool).readableResult == "done")
        #expect(!finalTool.outputTruncated)

        let canonical = tool(
            "read",
            response: .object(["truncation": .object(["truncated": .bool(true)])])
        )
        #expect(canonical.outputTruncated)
        #expect(!tool(
            "read",
            response: .object(["truncation": .object(["truncated": .bool(false)])])
        ).outputTruncated)
        #expect(!tool(
            "read",
            response: .object(["truncation": .null])
        ).outputTruncated)
        #expect(!tool(
            "read",
            response: .object(["details": .object(["truncation": .object(["truncated": .bool(false)])])])
        ).outputTruncated)
    }

    @Test("authoritative response patch wins over requested edit blocks")
    func authoritativePatch() throws {
        let request: JSONValue = .object([
            "path": .string("file.swift"),
            "edits": .array([.object(["oldText": .string("old"), "newText": .string("new")])]),
        ])
        let response: JSONValue = .object([
            "details": .object([
                "patch": .string("--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+settled")
            ])
        ])
        let diff = try #require(ToolDiffPresentation.make(request: request, response: response))
        #expect(diff.sourceLabel == "Applied diff")
        #expect(diff.lines.contains { $0.kind == .removal && $0.text == "old" })
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "settled" })
        #expect(!diff.lines.contains { $0.kind == .addition && $0.text == "new" })
    }

    @Test("generic unified patches reuse the bounded diff presentation")
    func genericUnifiedPatch() throws {
        let diff = try #require(ToolDiffPresentation.make(
            unifiedPatch: "--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new",
            sourceLabel: "Git diff"
        ))
        #expect(diff.sourceLabel == "Git diff")
        #expect(diff.requestedChangeCount == nil)
        #expect(diff.lines.contains { $0.kind == .removal && $0.text == "old" })
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "new" })
    }

    @Test("authoritative patch admission is exact and fails closed")
    func inlineDiffAdmission() throws {
        let oneRequest: JSONValue = .object(["edits": .array([
            .object(["oldText": .string("old"), "newText": .string("new")]),
        ])])
        func diff(_ patch: String) throws -> ToolDiffPresentation {
            try #require(ToolDiffPresentation.make(
                request: oneRequest,
                response: .object(["patch": .string(patch)])
            ))
        }

        let oneTextFile = try diff(
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new"
        )
        #expect(oneTextFile.requestedChangeCount == 1)
        #expect(oneTextFile.diffUnitCount == 1)
        #expect(oneTextFile.hasChangeContent)
        #expect(oneTextFile.showsInline)

        let twoHunks = try diff(
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n@@ -8 +8 @@\n-before\n+after"
        )
        #expect(twoHunks.diffUnitCount == 2)
        #expect(!twoHunks.showsInline)

        let textAndBinary = try diff(
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n"
                + "diff --git a/image.png b/image.png\nnew file mode 100644\nBinary files /dev/null and b/image.png differ"
        )
        #expect(textAndBinary.diffUnitCount == 2)
        #expect(!textAndBinary.showsInline)

        let headerLightMultiFile = try diff(
            "--- a/first\n+++ b/first\n@@ -1 +1 @@\n-old\n+new\n"
                + "--- a/second\n+++ b/second\n@@ -1 +1 @@\n-before\n+after"
        )
        #expect(headerLightMultiFile.diffUnitCount == nil)
        #expect(!headerLightMultiFile.showsInline)
        #expect(headerLightMultiFile.lines.contains { $0.kind == .removal && $0.text == "-- a/second" })
        #expect(headerLightMultiFile.lines.contains { $0.kind == .addition && $0.text == "++ b/second" })

        let combined = try diff(
            "diff --cc file\nindex 111,222..333\n--- a/file\n+++ b/file\n@@@ -1,1 -1,1 +1,1 @@@\n-old\n+new"
        )
        #expect(combined.diffUnitCount == nil)
        #expect(!combined.showsInline)

        for malformedHeader in ["@@ -x +1 @@", "@@ -1 +1"] {
            let malformed = try diff(
                "diff --git a/file b/file\n--- a/file\n+++ b/file\n\(malformedHeader)\n-old\n+new"
            )
            #expect(malformed.diffUnitCount == nil)
            #expect(!malformed.showsInline)
        }

        let headerOnly = try diff("diff --git a/file b/file\n--- a/file\n+++ b/file")
        #expect(headerOnly.diffUnitCount == 1)
        #expect(!headerOnly.hasChangeContent)
        #expect(!headerOnly.showsInline)

        let multipleRequest: JSONValue = .object(["edits": .array([
            .object(["oldText": .string("one"), "newText": .string("two")]),
            .object(["oldText": .string("three"), "newText": .string("four")]),
        ])])
        let multiple = try #require(ToolDiffPresentation.make(request: multipleRequest, response: nil))
        #expect(multiple.requestedChangeCount == 2)
        #expect(multiple.diffUnitCount == 2)
        #expect(!multiple.showsInline)
        #expect(multiple.changesTitle == "View 2 changes")

        let unavailable = try #require(ToolDiffPresentation.make(
            request: nil,
            response: .object(["patch": .string("@@ -1 +1 @@\n-old\n+new")])
        ))
        #expect(unavailable.requestedChangeCount == nil)
        #expect(unavailable.diffUnitCount == 1)
        #expect(!unavailable.showsInline)
        #expect(unavailable.changesTitle == "View changes")
    }

    @Test("compact inline diff preserves semantics and expands by density")
    func diffDensity() throws {
        let context = (0..<30).map { " line-\($0)" }.joined(separator: "\n")
        let diff = try #require(ToolDiffPresentation.make(
            request: .object(["edits": .array([
                .object(["oldText": .string("old"), "newText": .string("new")]),
            ])]),
            response: .object(["patch": .string("@@ -1,30 +1,30 @@\n\(context)\n-old\n+new")])
        ))
        let glance = diff.visibleLines(for: .glance)
        let expanded = diff.visibleLines(for: .expanded)
        #expect(glance.count == ToolDiffPresentation.compactMaximumVisibleLines)
        #expect(glance.contains { if case .omitted = $0.kind { true } else { false } })
        #expect(glance.contains { $0.kind == .addition && $0.text == "new" })
        #expect(glance.contains { $0.kind == .removal && $0.text == "old" })
        #expect(expanded == diff.lines)
        #expect(expanded.count > glance.count)
    }

    @Test("in-progress edits render faithful removed and added blocks")
    func requestedEditBlocks() throws {
        let request: JSONValue = .object([
            "path": .string("file.swift"),
            "edits": .array([
                .object(["oldText": .string("one\ntwo"), "newText": .string("one\nthree")]),
                .object(["oldText": .string("four"), "newText": .string("five")]),
            ]),
        ])
        let diff = try #require(ToolDiffPresentation.make(request: request, response: nil))
        #expect(diff.sourceLabel == "Requested changes")
        #expect(diff.lines.filter { $0.kind == .hunk }.count == 2)
        #expect(diff.lines.contains { $0.kind == .removal && $0.text == "two" })
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "three" })
    }

    @Test("pure insertion and deletion omit fabricated blank diff rows")
    func pureInsertionAndDeletion() throws {
        let insertion = try #require(ToolDiffPresentation.make(
            request: .object(["edits": .array([.object([
                "oldText": .string(""),
                "newText": .string("first\n\nthird"),
            ])])]),
            response: nil
        ))
        #expect(insertion.lines.filter { $0.kind == .removal }.isEmpty)
        #expect(insertion.lines.filter { $0.kind == .addition }.map(\.text) == ["first", "", "third"])

        let deletion = try #require(ToolDiffPresentation.make(
            request: .object(["edits": .array([.object([
                "oldText": .string("first\n\nthird"),
                "newText": .string(""),
            ])])]),
            response: nil
        ))
        #expect(deletion.lines.filter { $0.kind == .addition }.isEmpty)
        #expect(deletion.lines.filter { $0.kind == .removal }.map(\.text) == ["first", "", "third"])
    }

    @Test("malformed edit payload does not fabricate a diff")
    func malformedEdit() {
        let request: JSONValue = .object([
            "path": .string("file.swift"),
            "edits": .array([.object(["oldText": .number(1), "newText": .string("new")])]),
        ])
        #expect(ToolDiffPresentation.make(request: request, response: nil) == nil)
    }

    @Test("only real unified file headers are metadata")
    func unifiedHeaderClassification() throws {
        let patch = "--- a/file.swift\n+++ b/file.swift\n---counter\n+++counter\n@@ -1 +1 @@\n--- source content\n+++ replacement content"
        let diff = try #require(ToolDiffPresentation.make(
            request: nil,
            response: .object(["patch": .string(patch)])
        ))
        #expect(diff.lines[0].kind == .metadata)
        #expect(diff.lines[1].kind == .metadata)
        #expect(diff.lines[2].kind == .removal)
        #expect(diff.lines[2].text == "--counter")
        #expect(diff.lines[3].kind == .addition)
        #expect(diff.lines[3].text == "++counter")
        #expect(diff.lines[4].kind == .hunk)
        #expect(diff.lines[5].kind == .removal)
        #expect(diff.lines[5].text == "-- source content")
        #expect(diff.lines[6].kind == .addition)
        #expect(diff.lines[6].text == "++ replacement content")
        #expect(diff.diffUnitCount == nil)
        #expect(!diff.showsInline)
    }

    @Test("diff omission boundary is exact at 359, 360, and 361 lines")
    func exactDiffBoundary() throws {
        for (count, expectedOmitted) in [(359, 0), (360, 1), (361, 2)] {
            let patch = (0..<count).map { "+line-\($0)" }.joined(separator: "\n")
            let diff = try #require(ToolDiffPresentation.make(
                request: nil,
                response: .object(["diff": .string(patch)])
            ))
            let omitted = diff.lines.compactMap { line -> Int? in
                guard case .omitted(let value) = line.kind else { return nil }
                return value
            }
            #expect(diff.totalLineCount == count)
            #expect(omitted == (expectedOmitted == 0 ? [] : [expectedOmitted]))
            #expect(diff.lines.first?.text == "line-0")
            #expect(diff.lines.last?.text == "line-\(count - 1)")
            if count == 359 {
                #expect(diff.lines[240].text == "line-240")
            } else {
                #expect(diff.lines[239].text == "line-239")
                #expect(diff.lines[240].kind == .omitted(expectedOmitted))
                #expect(diff.lines[241].text == "line-\(count - 119)")
            }
        }
    }

    @Test("large diffs retain bounded head and tail without retaining every source line")
    func boundedDiff() throws {
        let patch = (0..<20_000).map { "+line-\($0)" }.joined(separator: "\n")
        let diff = try #require(ToolDiffPresentation.make(
            request: nil,
            response: .object(["diff": .string(patch)])
        ))
        #expect(diff.lines.count == ToolDiffPresentation.maximumVisibleLines)
        #expect(diff.totalLineCount == 20_000)
        let omitted = diff.lines.compactMap { line -> Int? in
            guard case .omitted(let count) = line.kind else { return nil }
            return count
        }
        #expect(omitted == [19_641])
        #expect(diff.lines.first?.text == "line-0")
        #expect(diff.lines.last?.text == "line-19999")
        let glanceOmitted = diff.compactLines.compactMap { line -> Int? in
            guard case .omitted(let count) = line.kind else { return nil }
            return count
        }
        #expect(glanceOmitted == [19_987])
        #expect(diff.compactLines.first?.text == "line-0")
        #expect(diff.compactLines.last?.text == "line-19999")
    }

    @Test("diff source identities are shared across densities and remain stable as tails roll")
    func stableDiffLineIdentity() throws {
        func makeDiff(_ count: Int) throws -> ToolDiffPresentation {
            let patch = (0..<count).map { "+line-\($0)" }.joined(separator: "\n")
            return try #require(ToolDiffPresentation.make(
                request: nil,
                response: .object(["diff": .string(patch)])
            ))
        }

        let first = try makeDiff(400)
        #expect(Set(first.lines.map(\.id)).count == first.lines.count)
        #expect(Set(first.compactLines.map(\.id)).count == first.compactLines.count)
        let expandedByID = Dictionary(uniqueKeysWithValues: first.lines.map { ($0.id, $0) })
        for compactLine in first.compactLines {
            if case .source = compactLine.id {
                let expanded = try #require(expandedByID[compactLine.id])
                #expect(expanded.kind == compactLine.kind)
                #expect(expanded.text == compactLine.text)
            }
        }
        let expandedOmission = try #require(first.lines.first { if case .omission = $0.id { true } else { false } })
        let glanceOmission = try #require(first.compactLines.first { if case .omission = $0.id { true } else { false } })
        #expect(expandedOmission.id != glanceOmission.id)

        let rolled = try makeDiff(401)
        let firstByID = Dictionary(uniqueKeysWithValues: first.lines.map { ($0.id, $0) })
        let rolledByID = Dictionary(uniqueKeysWithValues: rolled.lines.map { ($0.id, $0) })
        for id in Set(firstByID.keys).intersection(rolledByID.keys) {
            #expect(firstByID[id]?.kind == rolledByID[id]?.kind)
            #expect(firstByID[id]?.text == rolledByID[id]?.text)
        }
        let source281 = ToolDiffLineID.source(index: 281, kind: .addition, text: "line-281")
        let source400 = ToolDiffLineID.source(index: 400, kind: .addition, text: "line-400")
        #expect(first.lines.contains { $0.id == source281 })
        #expect(!rolled.lines.contains { $0.id == source281 })
        #expect(rolled.lines.contains { $0.id == source400 })

        let changedAtSameIndex = try #require(ToolDiffPresentation.make(
            request: nil,
            response: .object(["diff": .string("+different")])
        ))
        #expect(changedAtSameIndex.lines[0].id != ToolDiffLineID.source(
            index: 0,
            kind: .addition,
            text: "line-0"
        ))
    }

    @Test("one pathological diff line is character bounded with disclosure")
    func boundedDiffLine() throws {
        let diff = try #require(ToolDiffPresentation.make(
            request: nil,
            response: .object(["diff": .string("+" + String(repeating: "x", count: 50_000))])
        ))
        #expect(diff.totalLineCount == 1)
        #expect(diff.lines.count == 1)
        #expect(diff.lines[0].kind == .addition)
        #expect(diff.lines[0].text.count <= ToolDiffPresentation.maximumRenderedLineCharacters)
        #expect(diff.lines[0].text.contains("characters omitted"))
    }

    @Test("built-in matching is exact and mixed-case extension names stay generic")
    func exactBuiltInNames() {
        let presentation = ToolDetailPresentation(tool: tool(
            "Read",
            request: .object(["path": .string("extension.data")])
        ))
        #expect(presentation.kind == .generic)
        #expect(presentation.displayTitle == "Read")
        #expect(presentation.icon == "wrench.and.screwdriver")
        #expect(presentation.primaryLabel == "File")
    }

    @Test("generic tools foreground one exact high-signal string and otherwise omit request chrome")
    func genericPrimary() {
        let subagent = ToolDetailPresentation(tool: tool(
            "subagent",
            request: .object(["task": .string("Review paging correctness"), "id": .string("child")])
        ))
        #expect(subagent.kind == .generic)
        #expect(subagent.primaryLabel == "Task")
        #expect(subagent.primaryValue == "Review paging correctness")

        let web = ToolDetailPresentation(tool: tool(
            "web_search",
            request: .object(["query": .string("SwiftUI live sheet state"), "url": .string("https://example.com")])
        ))
        #expect(web.primaryLabel == "Query")
        #expect(web.primaryValue == "SwiftUI live sheet state")

        let unknown = ToolDetailPresentation(tool: tool(
            "project_echo",
            request: .object(["payload": .object(["nested": .bool(true)])])
        ))
        #expect(unknown.primaryLabel == nil)
        #expect(unknown.primaryValue == nil)
    }

    @Test("pathological command and output previews are bounded while normal text remains complete")
    func boundedTextPreviews() throws {
        let normal = ToolDetailPresentation(tool: tool(
            "bash",
            request: .object(["command": .string("swift test")]),
            content: "all tests passed"
        ))
        #expect(normal.primaryPreview?.text == "swift test")
        #expect(normal.primaryPreview?.isBounded == false)
        #expect(normal.readableResultPreview?.text == "all tests passed")

        let pathological = ToolDetailPresentation(tool: tool(
            "bash",
            request: .object(["command": .string(String(repeating: "c", count: 20_000))]),
            content: String(repeating: "o", count: 20_000)
        ))
        let command = try #require(pathological.primaryPreview)
        let output = try #require(pathological.readableResultPreview)
        #expect(command.isBounded)
        #expect(output.isBounded)
        #expect(command.text.count <= ToolTextPreview.maximumRenderedCharacters)
        #expect(output.text.count <= ToolTextPreview.maximumRenderedCharacters)
        #expect(command.text.contains("characters omitted"))
        #expect(output.text.contains("characters omitted"))
    }

    @Test("single-line preview reports every character hidden by its marker")
    func exactCharacterOmission() throws {
        let source = String(repeating: "x", count: ToolTextPreview.maximumLineCharacters + 1)
        let preview = ToolTextPreview.make(source)
        #expect(preview.isBounded)
        #expect(preview.text.count <= ToolTextPreview.maximumLineCharacters)
        #expect(preview.text.hasSuffix("[27 characters omitted]"))
        #expect(preview.text.filter { $0 == "x" }.count + 27 == source.count)
    }

    @Test("text preview line boundary retains exact head and tail with one marker")
    func exactTextLineBoundary() {
        for (count, expectedOmitted) in [(23, 0), (24, 1), (25, 2)] {
            let source = (0..<count).map { "line-\($0)" }.joined(separator: "\n")
            let preview = ToolTextPreview.make(source)
            #expect(preview.totalLineCount == count)
            #expect(preview.renderedLineCount == min(count, ToolTextPreview.maximumVisibleLines))
            #expect(preview.isBounded == (expectedOmitted > 0))
            #expect(preview.text.contains("[\(expectedOmitted) lines omitted") == (expectedOmitted > 0))
            #expect(preview.text.hasPrefix("line-0"))
            #expect(preview.text.hasSuffix("line-\(count - 1)"))
            let lines = preview.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if count == ToolTextPreview.maximumUnomittedLines {
                #expect(lines[ToolTextPreview.retainedHeadLines] == "line-\(ToolTextPreview.retainedHeadLines)")
            } else {
                #expect(lines[ToolTextPreview.retainedHeadLines].contains("lines omitted"))
                #expect(lines[ToolTextPreview.retainedHeadLines + 1] == "line-\(count - ToolTextPreview.retainedTailLines)")
            }
        }
    }

    @Test("thousands of blank lines remain line and character bounded")
    func blankLineBound() {
        let preview = ToolTextPreview.make(String(repeating: "\n", count: 6_000))
        #expect(preview.totalLineCount == 6_001)
        #expect(preview.renderedLineCount == ToolTextPreview.maximumVisibleLines)
        #expect(preview.text.count <= ToolTextPreview.maximumRenderedCharacters)
        #expect(preview.text.contains("lines omitted from preview"))
        #expect(preview.isBounded)
    }

    @Test("metadata strings are bounded while small scalar text remains unchanged")
    func boundedMetadata() throws {
        let longPath = String(repeating: "directory/", count: 1_000)
        let longGlob = String(repeating: "*.generated/", count: 1_000)
        let presentation = ToolDetailPresentation(tool: tool(
            "grep",
            request: .object([
                "pattern": .string("needle"), "path": .string(longPath), "glob": .string(longGlob),
                "context": .number(2), "ignoreCase": .bool(true),
            ])
        ))
        let location = try #require(presentation.metadata.first { $0.label == "Location" })
        let glob = try #require(presentation.metadata.first { $0.label == "File filter" })
        let context = try #require(presentation.metadata.first { $0.label == "Context lines" })
        let ignoreCase = try #require(presentation.metadata.first { $0.label == "Ignore case" })
        #expect(location.value == longPath)
        #expect(glob.value == longGlob)
        #expect(location.preview.isBounded)
        #expect(glob.preview.isBounded)
        #expect(location.preview.text.count <= ToolTextPreview.maximumRenderedCharacters)
        #expect(glob.preview.text.count <= ToolTextPreview.maximumRenderedCharacters)
        #expect(location.accessibilityLabel.count < 240)
        #expect(glob.accessibilityLabel.count < 240)
        #expect(location.accessibilityLabel.contains("Preview shortened; complete value in Technical details."))
        #expect(glob.accessibilityLabel.contains("Preview shortened; complete value in Technical details."))
        #expect(!location.accessibilityLabel.contains(longPath))
        #expect(!glob.accessibilityLabel.contains(longGlob))
        #expect(context.preview.text == "2")
        #expect(!context.preview.isBounded)
        #expect(ignoreCase.preview.text == "Yes")
        #expect(!ignoreCase.preview.isBounded)
    }

    @Test("technical result JSON resolves authoritative data without duplicating requests")
    func technicalResultResolution() {
        let request: JSONValue = .object(["command": .string("build")])
        let response: JSONValue = .object(["content": .string("authoritative")])
        let fallback: JSONValue = .object(["legacy": .string("result")])

        #expect(ToolTechnicalResultResolver.resolve(tool(
            "bash", request: request, fallbackContent: request
        )) == .null)
        #expect(ToolTechnicalResultResolver.resolve(tool(
            "bash", request: request, content: "complete content-only result"
        )) == .string("complete content-only result"))
        #expect(ToolTechnicalResultResolver.resolve(tool(
            "bash", request: request, response: response,
            content: "secondary content", fallbackContent: fallback
        )) == response)
        #expect(ToolTechnicalResultResolver.resolve(tool(
            "bash", request: request, fallbackContent: fallback
        )) == fallback)
        #expect(ToolTechnicalResultResolver.resolve(tool("bash")) == .null)
    }

    @Test("aggregate rows use raw names, bounded semantic context, and output tails")
    func aggregateRowPresentation() {
        let labeled = ChatToolPresentation(
            id: "labeled-bash", title: "Shell", toolName: "bash", subtitle: "Running",
            request: .object(["command": .string("swift test")]), response: nil,
            content: "first\n\nsecond\nthird", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:00Z", completedAt: nil, durationMs: 2_000,
            lastProgressAt: "2026-01-01T00:00:02Z", progressSequence: 2
        )
        let row = ToolRunRowPresentation(tool: labeled, at: Date(timeIntervalSince1970: 2))
        #expect(row.title == "Shell")
        #expect(row.icon == "terminal")
        #expect(row.primaryLabel == "Command")
        #expect(row.primaryPreview?.text == "swift test")
        #expect(row.outputPreview?.text == "second\nthird")
        #expect(row.outputPreview?.isBounded == true)
        #expect(row.outputPreview?.renderedLineCount == 2)
        #expect(row.isRunning)
        #expect(row.elapsedMilliseconds == 2_000)

        let generic = ToolRunRowPresentation(tool: tool(
            "custom", request: .object(["task": .string("inspect")]),
            response: .object(["items": .array([.string("one")])])
        ))
        #expect(generic.primaryLabel == "Task")
        #expect(generic.hasStructuredResult)
        #expect(generic.outputPreview == nil)

        let bounded = ToolRunRowPresentation(tool: tool(
            "bash", request: .object(["command": .string("build")]),
            content: "done", outputTruncated: true
        ))
        #expect(bounded.outputPreview?.text == "done")
        #expect(bounded.outputTruncated)

        let settled = ChatToolPresentation(
            id: labeled.id, title: labeled.title, toolName: labeled.toolName, subtitle: "Completed",
            request: labeled.request, response: .object(["content": .string("final")]),
            content: "final", fallbackContent: nil, error: false,
            startedAt: labeled.startedAt, completedAt: "2026-01-01T00:00:03Z", durationMs: 3_000,
            lastProgressAt: "2026-01-01T00:00:03Z", progressSequence: 3
        )
        let settledRow = ToolRunRowPresentation(tool: settled)
        #expect(settledRow.id == row.id)
        #expect(!settledRow.isRunning)
        #expect(settledRow.outputPreview?.text == "final")

        let ordered = ChatToolRunPresentation(tools: [labeled, tool("read")])
        #expect(ordered.reverseChronologicalTools.map(\.id) == ["call-read", "labeled-bash"])
    }

    @Test("output tail policy handles CRLF, blanks, Unicode, and long lines without unbounded output")
    func boundedOutputTail() {
        #expect(ToolOutputTailPreview.make("one\r\ntwo\r\n\r\n")?.text == "one\ntwo")
        #expect(ToolOutputTailPreview.make("  \n\n newest \n")?.text == "newest")
        let unicode = String(repeating: "🙂", count: 120)
            + String(repeating: "x", count: 180) + "TAIL\nfinished"
        let preview = ToolOutputTailPreview.make(unicode)
        #expect(preview?.text == "\(String(repeating: "x", count: 176))TAIL\nfinished")
        #expect(preview?.isBounded == true)
        #expect(preview?.renderedLineCount == 2)
        #expect(ToolOutputTailPreview.make("\n\n") == nil)
    }

    @Test("aggregate preview fades disclose omitted content only")
    func aggregatePreviewFadePolicy() {
        #expect(!ToolRowPreviewFadePolicy.showsFade(
            sourceIsBounded: false,
            fullHeight: 40,
            visibleHeight: 40
        ))
        #expect(ToolRowPreviewFadePolicy.showsFade(
            sourceIsBounded: true,
            fullHeight: 40,
            visibleHeight: 40
        ))
        #expect(ToolRowPreviewFadePolicy.showsFade(
            sourceIsBounded: false,
            fullHeight: 61,
            visibleHeight: 40
        ))
        #expect(!ToolRowPreviewFadePolicy.showsFade(
            sourceIsBounded: false,
            fullHeight: .infinity,
            visibleHeight: 40
        ))
    }

    @Test("unknown tools remain generic and surface structured results")
    func genericFallback() {
        let response: JSONValue = .object(["items": .array([.string("one"), .string("two")])])
        let presentation = ToolDetailPresentation(tool: tool(
            "project_echo",
            request: .object(["value": .string("hello")]),
            response: response
        ))
        #expect(presentation.kind == .generic)
        #expect(presentation.displayTitle == "project_echo")
        #expect(presentation.primaryValue == nil)
        #expect(presentation.readableResult == nil)
        #expect(presentation.structuredResult == response)
    }

    @Test("generic extension tools promote JSON text into the structured result table")
    func genericJSONTextResult() {
        let result = """
        {"goal":{"objective":"Count to 20","status":"complete","tokensUsed":26804}}
        """
        let presentation = ToolDetailPresentation(tool: tool(
            "Update Goal",
            content: result
        ))

        #expect(presentation.kind == .generic)
        #expect(presentation.prefersStructuredResult)
        #expect(presentation.structuredResult?.objectValue?["goal"]?.objectValue?["status"]?.stringValue
            == "complete")

        let response: JSONValue = .object(["authoritative": .bool(true)])
        let responseWins = ToolDetailPresentation(tool: tool(
            "Extension Result",
            response: response,
            content: result
        ))
        #expect(responseWins.structuredResult == response)

        let fallback: JSONValue = .object([
            "result": .string("{\"ok\":true}"),
            "metadata": .string("preserved"),
        ])
        let fallbackEnvelope = ToolDetailPresentation(tool: tool(
            "Fallback Result",
            content: "{\"ok\":true}",
            fallbackContent: fallback
        ))
        #expect(fallbackEnvelope.structuredResult == fallback)

        let arrayResult = ToolDetailPresentation(tool: tool(
            "Array Result",
            response: .string("[1,2,3]")
        ))
        #expect(arrayResult.structuredResult == .array([.number(1), .number(2), .number(3)]))

        let malformed = ToolDetailPresentation(tool: tool(
            "Malformed Result",
            content: "{not-json}",
            outputTruncated: true
        ))
        #expect(!malformed.prefersStructuredResult)
        #expect(malformed.structuredResult == nil)

        let request: JSONValue = .object(["same": .string("value")])
        let duplicateFallback = ToolDetailPresentation(tool: tool(
            "Duplicate Fallback",
            request: request,
            fallbackContent: request
        ))
        #expect(duplicateFallback.structuredResult == nil)
    }

    private func tool(
        _ title: String,
        toolName: String? = nil,
        subtitle: String = "Completed",
        request: JSONValue? = nil,
        response: JSONValue? = nil,
        content: String = "",
        fallbackContent: JSONValue? = nil,
        outputTruncated: Bool = false
    ) -> ChatToolPresentation {
        ChatToolPresentation(
            id: "call-\(title)",
            title: title,
            toolName: toolName,
            subtitle: subtitle,
            request: request,
            response: response,
            content: content,
            fallbackContent: fallbackContent,
            error: false,
            startedAt: "2026-01-01T00:00:00Z",
            completedAt: subtitle == "Running" ? nil : "2026-01-01T00:00:01Z",
            durationMs: subtitle == "Running" ? nil : 1_000,
            lastProgressAt: "2026-01-01T00:00:00Z",
            progressSequence: 1,
            outputTruncated: outputTruncated
        )
    }
}
