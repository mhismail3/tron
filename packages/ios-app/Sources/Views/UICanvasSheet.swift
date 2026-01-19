import SwiftUI

/// Main sheet view for rendering agent-generated UI canvases
/// Uses Tron theme styling with glass effects
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(state.activeCanvas?.title ?? "")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        state.dismissCanvas()
                    } label: {
                        Text("Done")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .tint(.tronEmerald)
    }

    // MARK: - Content View

    @ViewBuilder
    private func contentView(canvas: UICanvasData) -> some View {
        if let root = canvas.parsedRoot {
            ScrollView(.vertical, showsIndicators: false) {
                UIComponentView(
                    component: root,
                    state: state
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            emptyView
        }
    }

    // MARK: - Rendering View (Progressive)

    private func renderingView(canvas: UICanvasData) -> some View {
        VStack(spacing: 0) {
            if let root = canvas.parsedRoot {
                // Show progressively rendered content
                ScrollView(.vertical, showsIndicators: false) {
                    UIComponentView(
                        component: root,
                        state: state
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Spacer()
            }

            // Loading indicator at bottom
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.tronEmerald)
                    .scaleEffect(0.8)
                Text("Rendering...")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.tronSurface.opacity(0.8))
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tronError)

            Text("Render Error")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tronTextPrimary)

            Text(message)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.tronTextMuted)

            Text("No content")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
