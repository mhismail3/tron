import Foundation

enum TronDevCommand: String, CaseIterable, Sendable {
    case startBackground
    case startBackgroundWithTests
    case startBackgroundWithBuildAndTests

    static let notificationUserInfoKey = "command"

    static let menuCommands: [Self] = [
        .startBackground,
        .startBackgroundWithTests,
        .startBackgroundWithBuildAndTests,
    ]

    var title: String {
        switch self {
        case .startBackground:
            return "Start dev server"
        case .startBackgroundWithTests:
            return "Start dev server after tests"
        case .startBackgroundWithBuildAndTests:
            return "Build, test, and start dev server"
        }
    }

    var arguments: [String] {
        switch self {
        case .startBackground:
            return ["dev", "-d"]
        case .startBackgroundWithTests:
            return ["dev", "-td"]
        case .startBackgroundWithBuildAndTests:
            return ["dev", "-btd"]
        }
    }

    var successTitle: String {
        switch self {
        case .startBackground, .startBackgroundWithTests, .startBackgroundWithBuildAndTests:
            return "Dev server command finished"
        }
    }

    var startsDevServer: Bool {
        switch self {
        case .startBackground, .startBackgroundWithTests, .startBackgroundWithBuildAndTests:
            return true
        }
    }

    func isEnabled(snapshot: ServerStatusSnapshot, controlsEnabled: Bool) -> Bool {
        controlsEnabled && !snapshot.isDevServerActive
    }

    func userInfo() -> [String: String] {
        [Self.notificationUserInfoKey: rawValue]
    }
}

enum TronDevCommandResult: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
}

struct TronDevCommandInvocation: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var currentDirectory: URL
    var logURL: URL
}

enum TronDevCommandRunner {
    typealias ProcessRunner = @Sendable (TronDevCommandInvocation) async -> ProcessResult

    static func run(
        command: TronDevCommand,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        logURL: URL = TronPaths.runDir.appendingPathComponent("dev-menu-command.log", isDirectory: false),
        fileManager: FileManager = .default,
        processRunner: @escaping ProcessRunner = runProcess
    ) async -> TronDevCommandResult {
        guard let projectRoot = resolveProjectRoot(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectory: currentDirectory,
            fileManager: fileManager
        ) else {
            return .failed(
                "Could not find scripts/tron. Set TRON_PROJECT_ROOT to your Tron checkout and reopen the app."
            )
        }

        let scriptURL = projectRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
        let invocation = TronDevCommandInvocation(
            executable: URL(fileURLWithPath: "/bin/bash", isDirectory: false),
            arguments: [scriptURL.path] + command.arguments,
            currentDirectory: projectRoot,
            logURL: logURL
        )
        let result = await processRunner(invocation)
        if result.exitCode == 0 {
            return .succeeded("Ran `scripts/tron \(command.arguments.joined(separator: " "))`.")
        }

        let detail = firstNonEmptyLine(result.stderr) ?? firstNonEmptyLine(result.stdout)
        if let detail {
            return .failed("\(detail)\n\nFull output: \(logURL.path)")
        }
        return .failed("Command exited with status \(result.exitCode).\n\nFull output: \(logURL.path)")
    }

    static func resolveProjectRoot(
        environment: [String: String],
        bundleURL: URL,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["TRON_PROJECT_ROOT"], !override.isEmpty {
            let candidate = URL(fileURLWithPath: override, isDirectory: true)
            if hasTronScript(candidate, fileManager: fileManager) {
                return candidate
            }
        }

        for origin in [bundleURL, currentDirectory] {
            if let found = findProjectRoot(ascendingFrom: origin, fileManager: fileManager) {
                return found
            }
        }
        return nil
    }

    private static func findProjectRoot(ascendingFrom origin: URL, fileManager: FileManager) -> URL? {
        var candidate = origin.resolvingSymlinksInPath()
        if !candidate.hasDirectoryPath {
            candidate.deleteLastPathComponent()
        }

        while true {
            if hasTronScript(candidate, fileManager: fileManager) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private static func hasTronScript(_ root: URL, fileManager: FileManager) -> Bool {
        let script = root
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: script.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func runProcess(_ invocation: TronDevCommandInvocation) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            do {
                try FileManager.default.createDirectory(
                    at: invocation.logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: invocation.logURL.path) {
                    FileManager.default.createFile(atPath: invocation.logURL.path, contents: nil)
                }
                let log = try FileHandle(forWritingTo: invocation.logURL)
                try log.seekToEnd()
                writeLogHeader(to: log, invocation: invocation)

                let process = Process()
                process.executableURL = invocation.executable
                process.arguments = invocation.arguments
                process.currentDirectoryURL = invocation.currentDirectory
                process.standardOutput = log
                process.standardError = log
                process.terminationHandler = { proc in
                    try? log.close()
                    continuation.resume(returning: ProcessResult(
                        exitCode: Int(proc.terminationStatus),
                        stdout: "",
                        stderr: ""
                    ))
                }
                try process.run()
            } catch {
                continuation.resume(returning: ProcessResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                ))
            }
        }
    }

    private static func writeLogHeader(to log: FileHandle, invocation: TronDevCommandInvocation) {
        let command = ([invocation.executable.path] + invocation.arguments).joined(separator: " ")
        let header = """

        === \(Date()) ===
        cwd: \(invocation.currentDirectory.path)
        command: \(command)

        """
        if let data = header.data(using: .utf8) {
            log.write(data)
        }
    }

    private static func firstNonEmptyLine(_ value: String) -> String? {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
