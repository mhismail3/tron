import SwiftUI

/// Main sheet view for rendering agent-generated UI canvases
struct UICanvasSheet: View {
    let state: UICanvasState

    var body: some View {
        NavigationStack {
            Group {
                if let canvas = state.activeCanvas {
                    switch canvas.status {
                    case .rendering:
                        renderingView(canvas: canvas)
                    case .complete:
                        contentView(canvas: canvas)
                    case .error(let message):
                        errorView(message: message)
                    }
                } else {
                    emptyView
                }
            }
            .navigationTitle(state.activeCanvas?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        state.dismissCanvas()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Content View

    @ViewBuilder
    private func contentView(canvas: UICanvasData) -> some View {
        if let root = canvas.parsedRoot {
            ScrollView {
                UIComponentView(
                    component: root,
                    state: state
                )
                .padding()
            }
        } else {
            emptyView
        }
    }

    // MARK: - Rendering View (Progressive)

    private func renderingView(canvas: UICanvasData) -> some View {
        VStack(spacing: 16) {
            if let root = canvas.parsedRoot {
                // Show progressively rendered content
                ScrollView {
                    UIComponentView(
                        component: root,
                        state: state
                    )
                    .padding()
                }
            }

            // Loading indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Rendering...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom)
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Render Error")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("No content")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
