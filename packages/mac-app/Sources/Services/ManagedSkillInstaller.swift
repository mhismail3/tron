import Foundation

struct ManagedSkillSyncSummary: Equatable, Sendable {
    var synced: Int
    var skippedUserOwned: Int
    var removedStale: Int
}

enum ManagedSkillSyncResult: Equatable, Sendable {
    case synced(ManagedSkillSyncSummary)
    case failed(String)

    var succeeded: Bool {
        if case .synced = self { return true }
        return false
    }
}

enum ManagedSkillInstaller {
    enum Failure: LocalizedError, Equatable {
        case missingSource(URL)
        case missingManagedSkills(URL)
        case sourceSkillMissingManagedSentinel(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let url):
                return "Missing bundled managed skills at \(url.path). Reinstall Tron.app."
            case .missingManagedSkills(let url):
                return "No bundled managed skills were found at \(url.path). Reinstall Tron.app."
            case .sourceSkillMissingManagedSentinel(let name):
                return "Bundled skill '\(name)' is missing its .managed sentinel. Reinstall Tron.app."
            }
        }
    }

    private static let excludedNames: Set<String> = ["node_modules", ".DS_Store"]

    static func sync(from source: URL, to destination: URL) throws -> ManagedSkillSyncSummary {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.missingSource(source)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceSkillDirs = try directChildDirectories(of: source)
        guard !sourceSkillDirs.isEmpty else {
            throw Failure.missingManagedSkills(source)
        }
        let sourceSkillNames = Set(sourceSkillDirs.map(\.lastPathComponent))
        var summary = ManagedSkillSyncSummary(synced: 0, skippedUserOwned: 0, removedStale: 0)

        for existing in try directChildDirectories(of: destination) {
            guard !sourceSkillNames.contains(existing.lastPathComponent), isManagedSkill(existing) else {
                continue
            }
            try fileManager.removeItem(at: existing)
            summary.removedStale += 1
        }

        for skillSource in sourceSkillDirs {
            let name = skillSource.lastPathComponent
            guard isManagedSkill(skillSource) else {
                throw Failure.sourceSkillMissingManagedSentinel(name)
            }

            let skillDestination = destination.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: skillDestination.path), !isManagedSkill(skillDestination) {
                summary.skippedUserOwned += 1
                continue
            }

            try replaceManagedSkill(from: skillSource, to: skillDestination)
            summary.synced += 1
        }

        return summary
    }

    private static func directChildDirectories(of directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        return try urls.filter { url in
            guard !excludedNames.contains(url.lastPathComponent) else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isManagedSkill(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".managed").path)
    }

    private static func copyDirectory(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for child in children {
            guard !excludedNames.contains(child.lastPathComponent) else { continue }
            let target = destination.appendingPathComponent(child.lastPathComponent)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectory(child, to: target)
            } else {
                try fileManager.copyItem(at: child, to: target)
            }
        }
    }

    private static func replaceManagedSkill(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).syncing.\(UUID().uuidString)", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try copyDirectory(source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }
}
