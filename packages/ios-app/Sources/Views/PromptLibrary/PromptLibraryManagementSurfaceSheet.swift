import SwiftUI

/// Generated-UI management for Prompt Library resources.
///
/// The fixed Prompt Library sheet remains a picker/composer insertion surface.
/// Create, update, delete, and clear actions are server-authored `ui_surface`
/// resources submitted through `ui::submit_action`.
@available(iOS 26.0, *)
struct PromptLibraryManagementSurfaceSheet: View {
    let engineClient: EngineClient

    @State private var selectedTab: PromptLibraryManagementTab = .snippets
    @State private var snippetsSurface: LoadedPromptManagementSurface?
    @State private var historySurface: LoadedPromptManagementSurface?
    @State private var loadingTabs: Set<PromptLibraryManagementTab> = []
    @State private var errorMessage: String?
    @State private var lastActionResult: UiActionResultDTO?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TronSegmentedControl(
                    options: PromptLibraryManagementTab.allCases.map { tab in
                        (label: tab.title, value: tab)
                    },
                    selection: $selectedTab
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if loadingTabs.contains(selectedTab) && currentSurface == nil {
                            ProgressView()
                                .tint(.tronEmerald)
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else if let currentSurface {
                            GeneratedUISurfaceView(
                                surface: currentSurface.surface,
                                resourceRef: currentSurface.resourceRef,
                                observedVersionId: currentSurface.resourceRef.versionId,
                                onSubmit: { submission in
                                    Task { await submit(submission, for: selectedTab) }
                                }
                            )
                        } else {
                            generatedSurfaceEmptyState
                        }

                        if let lastActionResult {
                            actionResultView(lastActionResult)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Manage Prompts", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await load(selectedTab, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                    .accessibilityLabel("Refresh generated prompt management")
                    .disabled(loadingTabs.contains(selectedTab))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .tronErrorAlert(message: $errorMessage)
        }
        .adaptivePresentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .task { await load(selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            Task { await load(tab) }
        }
    }

    private var currentSurface: LoadedPromptManagementSurface? {
        switch selectedTab {
        case .snippets:
            snippetsSurface
        case .history:
            historySurface
        }
    }

    private var generatedSurfaceEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.gearshape")
                .font(TronTypography.sans(size: 36))
                .foregroundStyle(.tronEmerald.opacity(0.5))
            Text("No management surface")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("Refresh to request a server-authored prompt management surface.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func actionResultView(_ result: UiActionResultDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.actionId ?? "Generated action", systemImage: "checkmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            if let childInvocationId = result.childInvocationId {
                Text(childInvocationId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronEmerald.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @MainActor
    private func load(_ tab: PromptLibraryManagementTab, force: Bool = false) async {
        if !force, surface(for: tab) != nil { return }
        loadingTabs.insert(tab)
        defer { loadingTabs.remove(tab) }
        do {
            let result = try await engineClient.capability.surfaceForTarget(
                tab.surfaceRequest,
                idempotencyKey: .userAction("promptLibrary.manage.\(tab.rawValue).surface")
            )
            guard let surface = result.surface,
                  let resourceRef = result.resourceRefs.first
            else {
                errorMessage = "Generated prompt management surface was empty."
                return
            }
            let loaded = LoadedPromptManagementSurface(surface: surface, resourceRef: resourceRef)
            switch tab {
            case .snippets:
                snippetsSurface = loaded
            case .history:
                historySurface = loaded
            }
        } catch {
            errorMessage = "Failed to load management surface: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func submit(_ submission: UiActionSubmissionDTO, for tab: PromptLibraryManagementTab) async {
        do {
            lastActionResult = try await engineClient.capability.submitUiAction(
                submission,
                idempotencyKey: .userAction("promptLibrary.manage.\(tab.rawValue).\(submission.actionId)")
            )
            await load(tab, force: true)
        } catch {
            errorMessage = "Generated action failed: \(error.localizedDescription)"
        }
    }

    private func surface(for tab: PromptLibraryManagementTab) -> LoadedPromptManagementSurface? {
        switch tab {
        case .snippets:
            snippetsSurface
        case .history:
            historySurface
        }
    }
}

@available(iOS 26.0, *)
private enum PromptLibraryManagementTab: String, CaseIterable, Hashable {
    case snippets
    case history

    var title: String {
        switch self {
        case .snippets:
            "Snippets"
        case .history:
            "History"
        }
    }

    var surfaceRequest: UiSurfaceForTargetRequestDTO {
        UiSurfaceForTargetRequestDTO(
            targetType: "resource_collection",
            targetId: targetId,
            purpose: "Manage prompt library resources",
            layoutProfile: layoutProfile,
            maxPreviewBytes: 512
        )
    }

    private var targetId: String {
        switch self {
        case .snippets:
            "artifact:prompt-snippet"
        case .history:
            "artifact:prompt-history"
        }
    }

    private var layoutProfile: String {
        switch self {
        case .snippets:
            "prompt_library.snippets.v1"
        case .history:
            "prompt_library.history.v1"
        }
    }
}

private struct LoadedPromptManagementSurface {
    var surface: UiSurfaceDTO
    var resourceRef: UiSurfaceRefDTO
}
