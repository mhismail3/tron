import Testing
import Foundation

extension SourceGuardTests {

    @Test("iOS deep hierarchy roots have explicit count and budget gates")
    func testIOSDeepHierarchyRootsHaveExplicitCountAndBudgetGates() throws {
        let iosRoot = iosAppRoot()
        let nearBudgetWarningLineCount = 590
        let hardLineLimit = 700
        let watchedRoots: [HierarchyBudget] = [
            HierarchyBudget(
                relativePath: "Sources/Engine/Transport/Clients",
                minimumFileCount: 21,
                maximumFileCount: 24,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: ["Repositories"],
                requiredFiles: [
                    "Sources/Engine/Transport/Clients/SystemClient.swift",
                    "Sources/Engine/Transport/Clients/MessageClient.swift",
                    "Sources/Engine/Transport/Clients/LogsClient.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Sources/Engine/Transport/Retry",
                minimumFileCount: 8,
                maximumFileCount: 8,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Sources/Engine/Transport/Retry/ConnectionManager.swift",
                    "Sources/Engine/Transport/Retry/ConnectionErrorClassifier.swift",
                    "Sources/Engine/Transport/Retry/ConnectionToastPolicy.swift",
                    "Sources/Engine/Transport/Retry/NetworkDiagnosticsFormatter.swift",
                    "Sources/Engine/Transport/Retry/ReconnectProbePolicy.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Tests/Engine/Transport/Retry",
                minimumFileCount: 5,
                maximumFileCount: 5,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Tests/Engine/Transport/Retry/ConnectionManagerTests.swift",
                    "Tests/Engine/Transport/Retry/ConnectionErrorClassifierTests.swift",
                    "Tests/Engine/Transport/Retry/ConnectionToastPolicyTests.swift",
                    "Tests/Engine/Transport/Retry/NetworkDiagnosticsFormatterTests.swift",
                    "Tests/Engine/Transport/Retry/ReconnectProbePolicyTests.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Tests/Engine/Transport/WebSocket",
                minimumFileCount: 3,
                maximumFileCount: 3,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Tests/Engine/Transport/WebSocket/EngineClientTests.swift",
                    "Tests/Engine/Transport/WebSocket/WebSocketAuthTests.swift",
                    "Tests/Engine/Transport/WebSocket/EngineConnectionReconnectTests.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Sources/UI/Capabilities/Shared",
                minimumFileCount: 19,
                maximumFileCount: 22,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: []
            ),
            HierarchyBudget(
                relativePath: "Sources/UI/Settings/Shell",
                minimumFileCount: 13,
                maximumFileCount: 15,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: []
            ),
            HierarchyBudget(
                relativePath: "Sources/UI/Components",
                minimumFileCount: 12,
                maximumFileCount: 14,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: []
            ),
            HierarchyBudget(
                relativePath: "Tests/Session/Chat",
                minimumFileCount: 36,
                maximumFileCount: 42,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [
                    "Coordinators",
                    "Messaging",
                    "Navigation",
                    "State",
                    "ViewModel",
                ]
            ),
            HierarchyBudget(
                relativePath: "Tests/Session/Chat/Coordinators",
                minimumFileCount: 1,
                maximumFileCount: 1,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Tests/Session/Chat/Coordinators/MessagingCoordinatorTests.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Tests/Session/Chat/Messaging",
                minimumFileCount: 1,
                maximumFileCount: 2,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Tests/Session/Chat/Messaging/StreamingManagerTests.swift",
                    "Tests/Session/Chat/Messaging/StreamingManagerTypewriterTests.swift",
                ]
            ),
            HierarchyBudget(
                relativePath: "Tests/Session/Chat/ViewModel",
                minimumFileCount: 1,
                maximumFileCount: 1,
                maximumLineCount: hardLineLimit,
                allowedImmediateSubdirectories: [],
                requiredFiles: [
                    "Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift",
                ]
            ),
        ]

        var failures: [String] = []
        for budget in watchedRoots {
            let root = iosRoot.appendingPathComponent(budget.relativePath)
            let files = try swiftFiles(in: root)
            let fileCount = files.count
            if fileCount < budget.minimumFileCount || fileCount > budget.maximumFileCount {
                failures.append("\(budget.relativePath) has \(fileCount) Swift files, expected \(budget.minimumFileCount)...\(budget.maximumFileCount)")
            }

            let missingFiles = budget.requiredFiles
                .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
            failures.append(contentsOf: missingFiles.map { "\($0) is required by the deep hierarchy guard" })

            let unexpectedSubdirectories = try immediateSubdirectories(in: root)
                .filter { !budget.allowedImmediateSubdirectories.contains($0) }
            failures.append(contentsOf: unexpectedSubdirectories.map { "\(budget.relativePath)/\($0) is not an allowed immediate subdirectory" })

            let oversizedFiles = try files.compactMap { file -> String? in
                let lineCount = try sourceLineCount(file)
                guard lineCount > budget.maximumLineCount else { return nil }
                return "\(relativePath(file, from: iosRoot)) has \(lineCount) LOC"
            }
            failures.append(contentsOf: oversizedFiles)
        }

        #expect(
            failures.isEmpty,
            "iOS deep hierarchy/budget drift. Near-budget rows start at \(nearBudgetWarningLineCount) LOC; hard failures start above \(hardLineLimit) LOC. \(failures)"
        )
    }

    @Test("Swift near-budget files have explicit scorecard rows")
    func testSwiftNearBudgetFilesHaveExplicitScorecardRows() throws {
        let iosRoot = iosAppRoot()
        let repoRoot = iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scorecard = try String(
            contentsOf: repoRoot.appendingPathComponent("packages/agent/docs/post-hra-adversarial-hardening-scorecard.md"),
            encoding: .utf8
        )
        let nearBudgetWarningLineCount = 590
        let files = try swiftFiles(in: iosRoot.appendingPathComponent("Sources"))
            + swiftFiles(in: iosRoot.appendingPathComponent("Tests"))

        let missingRows = try files.compactMap { file -> String? in
            let lineCount = try sourceLineCount(file)
            guard lineCount >= nearBudgetWarningLineCount else { return nil }
            let path = relativePath(file, from: repoRoot)
            let expectedRowPrefix = "| `\(path)` | \(lineCount) |"
            return scorecard.contains(expectedRowPrefix) ? nil : "\(path) has \(lineCount) LOC"
        }

        #expect(
            missingRows.isEmpty,
            "Swift near-budget files at or above \(nearBudgetWarningLineCount) LOC must have explicit scorecard rows: \(missingRows)"
        )
    }

    @Test("iOS deployment-target availability annotations are not duplicated")
    func testIOSDeploymentTargetAvailabilityAnnotationsAreNotDuplicated() throws {
        let iosRoot = iosAppRoot()
        let files = try swiftFiles(in: iosRoot.appendingPathComponent("Sources"))
            + swiftFiles(in: iosRoot.appendingPathComponent("Tests"))
        let redundantAvailability = "@available(iOS " + "26.0, *)"
        let redundantAnnotations = try files.compactMap { file -> String? in
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(redundantAvailability) else { return nil }
            return relativePath(file, from: iosRoot)
        }

        #expect(
            redundantAnnotations.isEmpty,
            "iOS 26 is the deployment target; redundant deployment-target availability annotations remain in \(redundantAnnotations)"
        )
    }

    private struct HierarchyBudget {
        let relativePath: String
        let minimumFileCount: Int
        let maximumFileCount: Int
        let maximumLineCount: Int
        let allowedImmediateSubdirectories: Set<String>
        let requiredFiles: [String]

        init(
            relativePath: String,
            minimumFileCount: Int,
            maximumFileCount: Int,
            maximumLineCount: Int,
            allowedImmediateSubdirectories: Set<String>,
            requiredFiles: [String] = []
        ) {
            self.relativePath = relativePath
            self.minimumFileCount = minimumFileCount
            self.maximumFileCount = maximumFileCount
            self.maximumLineCount = maximumLineCount
            self.allowedImmediateSubdirectories = allowedImmediateSubdirectories
            self.requiredFiles = requiredFiles
        }
    }

    private func immediateSubdirectories(in root: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func relativePath(_ file: URL, from root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return file.path }
        return String(file.path.dropFirst(rootPath.count))
    }

}
