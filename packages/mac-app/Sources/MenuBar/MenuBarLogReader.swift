import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case tronBinaryMissing
    case commandFailed(String)
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .tronBinaryMissing:
            return "The Tron runtime CLI was not found. Reinstall Tron or run the installer again."
        case .commandFailed(let detail):
            return detail.isEmpty ? "tron logs failed." : detail
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200

    static func commandArguments(limit: Int = defaultLimit, outputFile: URL) -> [String] {
        ["logs", "-n", String(limit), "-o", outputFile.path]
    }

    static func fetchRecentLogs(tronBinary: URL? = nil, limit: Int = defaultLimit) async -> Result<String, MenuBarLogReadError> {
        guard let tron = tronBinary ?? TronCLI.resolveBinary() else {
            return .failure(.tronBinaryMissing)
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-menu-logs-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = await Subprocess.run(
            executable: tron,
            arguments: commandArguments(limit: limit, outputFile: output)
        )

        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            return .failure(.commandFailed(detail))
        }

        do {
            return .success(try String(contentsOf: output, encoding: .utf8))
        } catch {
            return .failure(.unreadableOutput("Could not read log output: \(error.localizedDescription)"))
        }
    }
}
