import Foundation

/// Manages state for UI canvas rendering and interaction
@Observable
@MainActor
final class UICanvasState {
    // MARK: - Published State

    /// All active canvases by canvasId
    private(set) var canvases: [String: UICanvasData] = [:]

    /// Currently displayed canvas ID
    var activeCanvasId: String?

    /// Whether the canvas sheet is shown
    var showSheet = false

    // MARK: - Persistence

    /// Artifact store for persisting completed canvases to disk
    private let artifactStore = CanvasArtifactStore()

    // MARK: - Callbacks

    /// Called when user taps a button
    var onAction: ((String, String) -> Void)?  // (canvasId, actionId)

    /// Called when user changes a form control
    var onStateChange: ((String, String, Any) -> Void)?  // (canvasId, bindingId, value)

    // MARK: - Canvas Lifecycle

    /// Start rendering a new canvas (or restart for retry)
    func startRender(canvasId: String, title: String?, toolCallId: String) {
        // Check if this is a retry for an existing canvas
        if var existing = canvases[canvasId] {
            // Keep the sheet open, just update status to rendering
            existing.status = .rendering
            existing.toolCallId = toolCallId
            existing.partialJSON = ""
            canvases[canvasId] = existing
            logger.info("Canvas retry started: \(canvasId)", category: .ui)
        } else {
            // New canvas
            let canvas = UICanvasData(
                canvasId: canvasId,
                title: title,
                toolCallId: toolCallId,
                status: .rendering
            )
            canvases[canvasId] = canvas
            activeCanvasId = canvasId
            showSheet = true
            logger.info("Canvas render started: \(canvasId)", category: .ui)
        }
    }

    /// Mark canvas as retrying (validation failed, agent will retry)
    func setRetrying(canvasId: String, attempt: Int, errors: String) {
        guard var canvas = canvases[canvasId] else {
            // Create a placeholder canvas if we haven't seen it yet
            let newCanvas = UICanvasData(
                canvasId: canvasId,
                title: nil,
                toolCallId: "",
                status: .retrying(attempt: attempt, errors: errors)
            )
            canvases[canvasId] = newCanvas
            activeCanvasId = canvasId
            showSheet = true
            logger.info("Canvas retry placeholder created: \(canvasId), attempt \(attempt)", category: .ui)
            return
        }

        canvas.status = .retrying(attempt: attempt, errors: errors)
        canvases[canvasId] = canvas
        logger.info("Canvas retrying: \(canvasId), attempt \(attempt)", category: .ui)
    }

    /// Update canvas with streaming JSON chunk
    func updateRender(canvasId: String, chunk: String, accumulated: String) {
        guard var canvas = canvases[canvasId] else {
            logger.warning("updateRender called for unknown canvas: \(canvasId)", category: .ui)
            return
        }

        canvas.partialJSON = accumulated

        // Parse the accumulated tool arguments JSON and extract the "ui" field.
        // The accumulated JSON has structure: {"canvasId": "...", "ui": {...}, "state": {...}}
        // We need to extract just the "ui" value and parse it as a component tree.
        if let component = UICanvasParser.parseFromArguments(accumulated) {
            canvas.parsedRoot = component
            logger.verbose("Progressive parse succeeded for canvas: \(canvasId)", category: .ui)
        }

        canvases[canvasId] = canvas
    }

    /// Complete canvas render with final UI tree
    /// - Parameters:
    ///   - canvasId: Unique canvas identifier
    ///   - ui: Parsed UI component tree
    ///   - rawUI: Raw UI dictionary from server (for persistence)
    ///   - state: Initial form state
    func completeRender(canvasId: String, ui: UICanvasComponent, rawUI: [String: AnyCodable]?, state: [String: AnyCodable]?) {
        guard var canvas = canvases[canvasId] else {
            logger.warning("completeRender called for unknown canvas: \(canvasId)", category: .ui)
            return
        }

        canvas.status = .complete
        canvas.parsedRoot = ui
        if let state = state {
            canvas.state = state
        }

        canvases[canvasId] = canvas
        logger.info("Canvas render complete: \(canvasId)", category: .ui)

        // Persist to disk for session resumption
        if let rawUI = rawUI {
            artifactStore.save(
                canvasId: canvasId,
                title: canvas.title,
                ui: rawUI,
                state: state
            )
        }
    }

    /// Mark canvas as error
    func errorRender(canvasId: String, error: String) {
        guard var canvas = canvases[canvasId] else {
            return
        }

        canvas.status = .error(error)
        canvases[canvasId] = canvas
        logger.error("Canvas render error: \(canvasId) - \(error)", category: .ui)
    }

    /// Dismiss the canvas sheet
    func dismissCanvas() {
        showSheet = false
        activeCanvasId = nil
    }

    /// Clear a specific canvas
    func clearCanvas(_ canvasId: String) {
        canvases.removeValue(forKey: canvasId)
        if activeCanvasId == canvasId {
            activeCanvasId = nil
            showSheet = false
        }
    }

    /// Clear all canvases
    func clearAllCanvases() {
        canvases.removeAll()
        activeCanvasId = nil
        showSheet = false
    }

    // MARK: - State Binding

    /// Get state value for a binding
    func getValue(for bindingId: String) -> AnyCodable? {
        guard let canvasId = activeCanvasId,
              let canvas = canvases[canvasId] else {
            return nil
        }
        return canvas.state[bindingId]
    }

    /// Update state value and notify
    func setValue(_ value: Any, for bindingId: String) {
        guard let canvasId = activeCanvasId,
              var canvas = canvases[canvasId] else {
            return
        }

        canvas.state[bindingId] = AnyCodable(value)
        canvases[canvasId] = canvas

        // Notify callback
        onStateChange?(canvasId, bindingId, value)
    }

    /// Get boolean value for toggles
    func getBool(for bindingId: String, default defaultValue: Bool = false) -> Bool {
        guard let value = getValue(for: bindingId) else {
            return defaultValue
        }
        if let boolValue = value.value as? Bool {
            return boolValue
        }
        return defaultValue
    }

    /// Get double value for sliders
    func getDouble(for bindingId: String, default defaultValue: Double = 0) -> Double {
        guard let value = getValue(for: bindingId) else {
            return defaultValue
        }
        if let doubleValue = value.value as? Double {
            return doubleValue
        }
        if let intValue = value.value as? Int {
            return Double(intValue)
        }
        return defaultValue
    }

    /// Get string value for text fields/pickers
    func getString(for bindingId: String, default defaultValue: String = "") -> String {
        guard let value = getValue(for: bindingId) else {
            return defaultValue
        }
        if let stringValue = value.value as? String {
            return stringValue
        }
        return defaultValue
    }

    // MARK: - Actions

    /// Handle button action
    func handleAction(_ actionId: String) {
        guard let canvasId = activeCanvasId else {
            logger.warning("handleAction called with no active canvas", category: .ui)
            return
        }

        logger.info("Canvas action: \(canvasId) -> \(actionId)", category: .ui)
        onAction?(canvasId, actionId)
    }

    // MARK: - Accessors

    /// Get active canvas data
    var activeCanvas: UICanvasData? {
        guard let canvasId = activeCanvasId else { return nil }
        return canvases[canvasId]
    }

    // MARK: - Chip Data Helper

    /// Get chip data for a canvas (used for reconstruction and status sync)
    func getChipData(for canvasId: String, toolCallId: String) -> RenderAppUIChipData? {
        guard let canvas = canvases[canvasId] else { return nil }

        let status: RenderAppUIStatus
        let errorMessage: String?

        switch canvas.status {
        case .rendering:
            status = .rendering
            errorMessage = nil
        case .retrying:
            // Retrying = validation failed, show as error (not tappable)
            status = .error
            errorMessage = "Error generating"
        case .complete:
            status = .complete
            errorMessage = nil
        case .error(let error):
            status = .error
            errorMessage = error
        }

        return RenderAppUIChipData(
            toolCallId: toolCallId,
            canvasId: canvasId,
            title: canvas.title,
            status: status,
            errorMessage: errorMessage
        )
    }

    // MARK: - Persistence Loading

    /// Load a canvas from disk if not already in memory.
    /// Used for session resumption when user taps a completed chip.
    /// Returns true if canvas was loaded or already exists.
    @discardableResult
    func loadFromDiskIfNeeded(canvasId: String, toolCallId: String) -> Bool {
        // Already in memory
        if canvases[canvasId] != nil {
            return true
        }

        // Try to load from disk
        guard let artifact = artifactStore.load(canvasId: canvasId) else {
            logger.warning("No artifact found for canvas: \(canvasId)", category: .ui)
            return false
        }

        // Parse the raw UI into component tree
        guard let component = UICanvasParser.parse(artifact.ui.mapValues { $0.value }) else {
            logger.error("Failed to parse UI from artifact: \(canvasId)", category: .ui)
            return false
        }

        // Reconstruct canvas data
        let canvas = UICanvasData(
            canvasId: canvasId,
            title: artifact.title,
            toolCallId: toolCallId,
            status: .complete,
            partialJSON: "",
            parsedRoot: component,
            state: artifact.state
        )

        canvases[canvasId] = canvas
        logger.info("Loaded canvas from disk: \(canvasId)", category: .ui)
        return true
    }

    /// Check if a canvas exists on disk (without loading it)
    func hasArtifact(canvasId: String) -> Bool {
        return artifactStore.exists(canvasId: canvasId)
    }
}
