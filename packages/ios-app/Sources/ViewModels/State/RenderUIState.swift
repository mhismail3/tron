import Foundation
import Observation

/// State management for the RenderUI system.
/// Tracks active canvases and sheet presentation.
@Observable
@MainActor
final class RenderUIState {
    /// Currently active canvas ID for the sheet
    var activeCanvasId: String?
    /// URL for the active WKWebView
    var activeURL: URL?
    /// Title for the active sheet
    var activeTitle: String?
    /// Current status
    var status: RenderUIStatus = .rendering
    /// Whether the sheet should be shown
    var showSheet = false
    /// All known canvases (canvasId -> data)
    var canvases: [String: RenderUICanvas] = [:]
}

/// Data for a single RenderUI canvas.
struct RenderUICanvas: Equatable {
    let canvasId: String
    let url: String
    let title: String?
    var status: RenderUIStatus
    var errorMessage: String?
}

extension RenderUIState {
    func startRender(canvasId: String, url: String, title: String?) {
        let canvas = RenderUICanvas(
            canvasId: canvasId,
            url: url,
            title: title,
            status: .rendering
        )
        canvases[canvasId] = canvas

        activeCanvasId = canvasId
        activeURL = URL(string: url)
        activeTitle = title
        status = .rendering
        showSheet = true
    }

    func markReady(canvasId: String, url: String) {
        canvases[canvasId]?.status = .ready
        if activeCanvasId == canvasId {
            status = .ready
        }
    }

    func markError(canvasId: String, error: String) {
        canvases[canvasId]?.status = .error
        canvases[canvasId]?.errorMessage = error
        if activeCanvasId == canvasId {
            status = .error
        }
    }

    func showCanvas(_ canvasId: String) {
        guard let canvas = canvases[canvasId] else { return }
        activeCanvasId = canvasId
        activeURL = URL(string: canvas.url)
        activeTitle = canvas.title
        status = canvas.status
        showSheet = true
    }
}
