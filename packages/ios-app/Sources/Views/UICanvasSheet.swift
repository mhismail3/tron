import SwiftUI

/// Main sheet view for rendering agent-generated UI canvases
/// Uses Tron theme styling with liquid glass effects (iOS 26+)
@available(iOS 26.0, *)
struct UICanvasSheet: View {
    let state: UICanvasState

    var body: some View {
        NavigationStack {
            Group {
                if let canvas = state.activeCanvas {
                    switch canvas.status {
                    case .rendering:
                        renderingView(canvas: canvas)
                    case .retrying(let attempt, let errors):
                        retryingView(canvas: canvas, attempt: attempt, errors: errors)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(state.activeCanvas?.title ?? "")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
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

            // Loading indicator at bottom with glass effect
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.tronEmerald)
                    .scaleEffect(0.8)
                Text("Rendering...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.tronEmerald.opacity(0.15)), in: Rectangle())
            }
        }
    }

    // MARK: - Retrying View

    private func retryingView(canvas: UICanvasData, attempt: Int, errors: String) -> some View {
        VStack(spacing: 0) {
            // Show any progressively rendered content (if available from previous attempt)
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
                Spacer()
            }

            // Retry indicator at bottom with glass effect
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.tronWarning)
                        .scaleEffect(0.8)
                    Text("Fixing issues (attempt \(attempt)/3)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronWarning)
                }

                // Show truncated error message
                Text(String(errors.prefix(100)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.tronWarning.opacity(0.15)), in: Rectangle())
            }
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

// MARK: - Fallback for iOS < 26

/// Fallback sheet without liquid glass effects for older iOS versions
struct UICanvasSheetFallback: View {
    let state: UICanvasState

    var body: some View {
        NavigationStack {
            Group {
                if let canvas = state.activeCanvas {
                    switch canvas.status {
                    case .rendering:
                        renderingView(canvas: canvas)
                    case .retrying(let attempt, let errors):
                        retryingView(canvas: canvas, attempt: attempt, errors: errors)
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
            .background(Color.tronSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(state.activeCanvas?.title ?? "")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
        .tint(.tronEmerald)
    }

    @ViewBuilder
    private func contentView(canvas: UICanvasData) -> some View {
        if let root = canvas.parsedRoot {
            ScrollView(.vertical, showsIndicators: false) {
                UIComponentView(component: root, state: state)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            emptyView
        }
    }

    private func renderingView(canvas: UICanvasData) -> some View {
        VStack(spacing: 0) {
            if let root = canvas.parsedRoot {
                ScrollView(.vertical, showsIndicators: false) {
                    UIComponentView(component: root, state: state)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Spacer()
            }

            HStack(spacing: 10) {
                ProgressView()
                    .tint(.tronEmerald)
                    .scaleEffect(0.8)
                Text("Rendering...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color.tronSurface.opacity(0.95))
        }
    }

    private func retryingView(canvas: UICanvasData, attempt: Int, errors: String) -> some View {
        VStack(spacing: 0) {
            if let root = canvas.parsedRoot {
                ScrollView(.vertical, showsIndicators: false) {
                    UIComponentView(component: root, state: state)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Spacer()
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.tronWarning)
                        .scaleEffect(0.8)
                    Text("Fixing issues (attempt \(attempt)/3)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronWarning)
                }
                Text(String(errors.prefix(100)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(Color.tronSurface.opacity(0.95))
        }
    }

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
