import Darwin
import Foundation

struct GatewayAppVersion: Codable, Equatable, Sendable {
    let canonicalVersion: String
    let buildNumber: String

    static func current(bundle: Bundle = .main) -> GatewayAppVersion {
        let canonical = bundle.object(forInfoDictionaryKey: "TRONCanonicalVersion") as? String
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return GatewayAppVersion(
            canonicalVersion: canonical ?? marketing ?? "unknown",
            buildNumber: build ?? "unknown"
        )
    }
}

struct GatewayAppState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let onboardingCompleted: Bool
    let preparedVersion: GatewayAppVersion

    init(
        onboardingCompleted: Bool,
        preparedVersion: GatewayAppVersion,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.onboardingCompleted = onboardingCompleted
        self.preparedVersion = preparedVersion
    }
}

enum GatewayStoredState: Equatable, Sendable {
    case missing
    case valid(GatewayAppState)
    case corrupt
}

protocol GatewayStatePersisting: Sendable {
    func read() -> GatewayStoredState
    func write(_ state: GatewayAppState) throws
    func remove() throws
}

struct FileGatewayStateStore: GatewayStatePersisting {
    let path: URL

    func read() -> GatewayStoredState {
        guard FileManager.default.fileExists(atPath: path.path) else { return .missing }
        guard ownerOnly(path),
              let data = try? Data(contentsOf: path),
              let state = try? JSONDecoder().decode(GatewayAppState.self, from: data),
              state.schemaVersion == GatewayAppState.currentSchemaVersion else {
            return .corrupt
        }
        return .valid(state)
    }

    func write(_ state: GatewayAppState) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let data = try JSONEncoder().encode(state)
        let temporary = directory.appendingPathComponent(".mac-app-state.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var writeError: Error?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    break
                }
                offset += count
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if close(descriptor) != 0, writeError == nil {
            writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if let writeError {
            guard unlink(temporary.path) == 0 || errno == ENOENT else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            throw writeError
        }
        guard rename(temporary.path, path.path) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            guard unlink(temporary.path) == 0 || errno == ENOENT else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            throw error
        }
        guard chmod(path.path, 0o600) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard fsync(directoryDescriptor) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(directoryDescriptor)
            throw error
        }
        guard close(directoryDescriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }

    private func ownerOnly(_ path: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }
}
