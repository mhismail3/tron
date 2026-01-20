import Foundation

// MARK: - Canvas Artifact Store

/// Persists rendered UI canvases to disk for session resumption.
/// Stores canvases in .tron/artifacts/canvases/{canvasId}.json
@MainActor
class CanvasArtifactStore {

    private let fileManager = FileManager.default
    private let artifactsDir: URL

    init() {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("CanvasArtifactStore: Unable to access Documents directory")
        }
        let tronDir = documentsURL.appendingPathComponent(".tron", isDirectory: true)
        let artifactsBaseDir = tronDir.appendingPathComponent("artifacts", isDirectory: true)
        self.artifactsDir = artifactsBaseDir.appendingPathComponent("canvases", isDirectory: true)

        // Create directories if needed
        try? fileManager.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        logger.info("Canvas artifact store initialized at \(artifactsDir.path)", category: .ui)
    }

    // MARK: - Save

    /// Save a completed canvas to disk
    func save(canvasId: String, title: String?, ui: [String: AnyCodable], state: [String: AnyCodable]?) {
        let artifact = CanvasArtifact(
            canvasId: canvasId,
            title: title,
            ui: ui,
            state: state ?? [:],
            savedAt: ISO8601DateFormatter().string(from: Date())
        )

        let fileURL = artifactsDir.appendingPathComponent("\(canvasId).json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(artifact)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved canvas artifact: \(canvasId)", category: .ui)
        } catch {
            logger.error("Failed to save canvas artifact \(canvasId): \(error.localizedDescription)", category: .ui)
        }
    }

    // MARK: - Load

    /// Load a canvas from disk by canvasId
    func load(canvasId: String) -> CanvasArtifact? {
        let fileURL = artifactsDir.appendingPathComponent("\(canvasId).json")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.debug("No artifact found for canvas: \(canvasId)", category: .ui)
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let artifact = try JSONDecoder().decode(CanvasArtifact.self, from: data)
            logger.info("Loaded canvas artifact: \(canvasId)", category: .ui)
            return artifact
        } catch {
            logger.error("Failed to load canvas artifact \(canvasId): \(error.localizedDescription)", category: .ui)
            return nil
        }
    }

    /// Check if a canvas artifact exists
    func exists(canvasId: String) -> Bool {
        let fileURL = artifactsDir.appendingPathComponent("\(canvasId).json")
        return fileManager.fileExists(atPath: fileURL.path)
    }

    // MARK: - Delete

    /// Delete a specific canvas artifact
    func delete(canvasId: String) {
        let fileURL = artifactsDir.appendingPathComponent("\(canvasId).json")
        try? fileManager.removeItem(at: fileURL)
        logger.debug("Deleted canvas artifact: \(canvasId)", category: .ui)
    }

    /// Delete all canvas artifacts older than a given date
    func deleteOlderThan(_ date: Date) {
        let isoFormatter = ISO8601DateFormatter()

        do {
            let files = try fileManager.contentsOfDirectory(at: artifactsDir, includingPropertiesForKeys: nil)
            var deletedCount = 0

            for fileURL in files where fileURL.pathExtension == "json" {
                if let data = try? Data(contentsOf: fileURL),
                   let artifact = try? JSONDecoder().decode(CanvasArtifact.self, from: data),
                   let savedDate = isoFormatter.date(from: artifact.savedAt),
                   savedDate < date {
                    try? fileManager.removeItem(at: fileURL)
                    deletedCount += 1
                }
            }

            if deletedCount > 0 {
                logger.info("Cleaned up \(deletedCount) old canvas artifacts", category: .ui)
            }
        } catch {
            logger.warning("Failed to enumerate canvas artifacts: \(error.localizedDescription)", category: .ui)
        }
    }

    /// Delete all canvas artifacts
    func deleteAll() {
        do {
            let files = try fileManager.contentsOfDirectory(at: artifactsDir, includingPropertiesForKeys: nil)
            for fileURL in files {
                try? fileManager.removeItem(at: fileURL)
            }
            logger.info("Deleted all canvas artifacts", category: .ui)
        } catch {
            logger.warning("Failed to delete canvas artifacts: \(error.localizedDescription)", category: .ui)
        }
    }
}

// MARK: - Canvas Artifact Model

/// Persisted canvas data for session resumption
struct CanvasArtifact: Codable {
    let canvasId: String
    let title: String?
    let ui: [String: AnyCodable]
    let state: [String: AnyCodable]
    let savedAt: String
}
