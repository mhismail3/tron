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

    // MARK: - Callbacks

    /// Called when user taps a button
    var onAction: ((String, String) -> Void)?  // (canvasId, actionId)

    /// Called when user changes a form control
    var onStateChange: ((String, String, Any) -> Void)?  // (canvasId, bindingId, value)

    // MARK: - Canvas Lifecycle

    /// Start rendering a new canvas
    func startRender(canvasId: String, title: String?, toolCallId: String) {
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

    /// Update canvas with streaming JSON chunk
    func updateRender(canvasId: String, chunk: String, accumulated: String) {
        guard var canvas = canvases[canvasId] else {
            logger.warning("updateRender called for unknown canvas: \(canvasId)", category: .ui)
            return
        }

        canvas.partialJSON = accumulated

        // Try to parse the accumulated JSON (with recovery for truncated input)
        if let component = UICanvasParser.parseProgressively(accumulated) {
            canvas.parsedRoot = component
        }

        canvases[canvasId] = canvas
    }

    /// Complete canvas render with final UI tree
    func completeRender(canvasId: String, ui: UICanvasComponent, state: [String: AnyCodable]?) {
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
}
