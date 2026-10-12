import SwiftUI
import TronMobileCore

/// Manage Session's model, thinking and context-window controls, and Manage
/// Home's controls for the Home chat, as one card. Each choice is an ordinary
/// session RPC; the pending state keeps it visible until the Gateway publishes
/// the receipt, so both sheets accept, reject and reconcile identically.
struct SessionModelConfigurationCard<Footer: View>: View {
    let sessionID: String
    let snapshot: SessionContextPresentation
    let onError: (Error) -> Void
    /// The card's last row after the controls: Manage Session's automatic
    /// compaction, or Manage Home's memory model.
    @ViewBuilder let footer: () -> Footer
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var pendingModelSelection: SessionPendingModelSelection?
    @State private var pendingContextWindow: SessionPendingSetting<Int?>?
    @State private var pendingThinking: SessionPendingSetting<String>?
    @State private var settingContextWindow = false

    // Observe revision only while a choice awaits projection, never for ordinary
    // streaming. A completed receipt may be superseded without changing a value.
    private var pendingConfigurationRevision: Int? {
        guard pendingModelSelection != nil || pendingThinking != nil || pendingContextWindow != nil else { return nil }
        return model.authoritativeSnapshot(for: sessionID)?.revision
    }

    private var configurationConnectionReason: String? {
        guard let target = model.presentationTarget(for: sessionID), model.admitsLiveSessionCommands(target) else {
            return "Waiting for the conversation to synchronize."
        }
        return nil
    }

    private var presentationSource: SessionContextPresentation? {
        model.sessionContextPresentation(for: sessionID)
    }

    private var configurationRowAccent: Color { .tronPurple }

    private var displayedSnapshot: SessionContextPresentation {
        // Manage Session freezes its own frame under a sheet. The model card
        // still supplies bounded live data to its visible Models descendant;
        // neither this read nor receipt retirement is a covered-surface load.
        presentationActivity.allowsDataPublication ? (presentationSource ?? snapshot) : snapshot
    }

    var body: some View {
        modelSummaryCard(displayedSnapshot)
            .background {
                if presentationActivity.allowsDataPublication {
                    Color.clear
                        .onChange(of: presentationSource, initial: true) { _, value in
                            reconcile(value)
                        }
                        .onChange(of: pendingConfigurationRevision) { _, _ in
                            reconcile(presentationSource)
                        }
                }
            }
            .onChange(of: presentationActivity) { previous, current in
                guard !previous.allowsDataPublication,
                      current.allowsDataPublication else { return }
                reconcile(presentationSource)
            }
    }

    private func modelSelection(_ snapshot: SessionContextPresentation) -> Binding<ModelRef?> {
        Binding(
            get: {
                SessionModelSelectionPresentation.displayed(pending: pendingModelSelection, authoritative: displayedSnapshot.model)
            },
            set: { selection in
                guard presentationActivity.allowsDataPublication,
                      let selection, pendingModelSelection == nil, pendingThinking == nil, !settingContextWindow,
                      selection != SessionModelSelectionPresentation.displayed(
                        pending: pendingModelSelection, authoritative: snapshot.model
                      ),
                      let current = model.sessionContextPresentation(for: sessionID),
                      current.runtimeGeneration == snapshot.runtimeGeneration,
                      current.configurationLockedReason == nil,
                      current.model == snapshot.model else { return }
                let pending = SessionPendingModelSelection(selection, snapshot: current)
                pendingModelSelection = pending
                pendingContextWindow = nil
                pendingThinking = nil
                Task {
                    do {
                        guard let admitted = model.sessionContextPresentation(for: sessionID),
                              pending.admitted(in: admitted) != nil, admitted.model == current.model,
                              admitted.configurationLockedReason == nil else {
                            pendingModelSelection = pendingModelSelection?.rejecting(pending.id)
                            return
                        }
                        let revision = try await model.setModel(selection, sessionID: sessionID)
                        pendingModelSelection = pendingModelSelection?.confirming(pending.id, revision: revision)
                        if presentationActivity.allowsDataPublication { reconcile(presentationSource) }
                    } catch is CancellationError {
                        // Refused receipt replay is terminal for this intent;
                        // uncertain accepted outcomes use outcome_unknown instead.
                        pendingModelSelection = pendingModelSelection?.rejecting(pending.id)
                    } catch {
                        // A retired request may not replace a newer intent's
                        // failure. The session-scoped notice is visible above
                        // the picker as well as its covered Manage surface.
                        guard pendingModelSelection?.id == pending.id else { return }
                        pendingModelSelection = nil
                        guard let current = model.sessionContextPresentation(for: sessionID),
                              pending.admitted(in: current) != nil else { return }
                        onError(error)
                    }
                }
            }
        )
    }

    private func modelSummaryCard(_ snapshot: SessionContextPresentation) -> some View {
        let thinkingScope = SessionThinkingEditScope(snapshot)
        let lockedReason = configurationConnectionReason ?? snapshot.configurationLockedReason
        let displayedThinking = pendingThinking?.admitted(in: snapshot)?.value ?? snapshot.thinkingLevel
        let selection = modelSelection(snapshot)
        let catalog = model.providerCatalog(for: .session(id: sessionID))?.models ?? []
        return SessionModelSummaryCard(
            selection: selection,
            catalog: catalog,
            selectionAvailability: (pendingThinking != nil || settingContextWindow || pendingModelSelection != nil)
                ? .applying : lockedReason.map(ModelSelectionAvailability.blocked) ?? .ready,
        ) {
            TronThinkingSelectionRow(
                selection: Binding(
                    get: { displayedThinking },
                    set: { level in
                        guard level != displayedThinking, pendingModelSelection == nil, pendingThinking == nil, !settingContextWindow,
                              presentationActivity.allowsPresentationPublication,
                              let current = model.sessionContextPresentation(for: sessionID),
                              thinkingScope.admits(level, in: current),
                              (pendingThinking?.admitted(in: current)?.value ?? current.thinkingLevel) == displayedThinking else { return }
                        let pending = SessionPendingSetting(level, snapshot: snapshot)
                        pendingThinking = pending
                        Task {
                            do {
                                // The task may start after a runtime/model replacement.
                                guard let current = model.sessionContextPresentation(for: sessionID),
                                      thinkingScope.admits(level, in: current), pendingModelSelection == nil else {
                                    pendingThinking = pendingThinking?.rejecting(pending.id)
                                    return
                                }
                                let revision = try await model.setThinking(level, sessionID: sessionID)
                                pendingThinking = pendingThinking?.confirming(pending.id, revision: revision)
                                if presentationActivity.allowsDataPublication { reconcile(presentationSource) }
                            } catch {
                                pendingThinking = pendingThinking?.rejecting(pending.id)
                                onError(error)
                            }
                        }
                    }
                ),
                levels: snapshot.availableThinkingLevels,
                accent: configurationRowAccent
            )
            .id(thinkingScope)
            .disabled(lockedReason != nil || pendingModelSelection != nil || pendingThinking != nil || settingContextWindow)
            if model.gatewayInfo?.capabilities.contains("context-window.v1") == true,
               let policy = snapshot.contextWindowPolicy {
                let pendingWindow = pendingContextWindow?.admitted(in: snapshot)
                TronSettingsDivider(accent: configurationRowAccent)
                ContextWindowSelectionRow(
                    selection: Binding(
                        get: { pendingWindow.map(\.value) ?? policy.override },
                        set: { value in
                            // Bind the request to the model shown when the
                            // control was rendered. A late tap after a model
                            // switch must never mutate the replacement model.
                            guard !settingContextWindow, pendingModelSelection == nil, pendingThinking == nil,
                                  let current = model.sessionContextPresentation(for: sessionID),
                                  current.configurationLockedReason == nil,
                                  current.runtimeGeneration == snapshot.runtimeGeneration,
                                  current.contextWindowPolicy?.model == policy.model else { return }
                            let pending = SessionPendingSetting(value, snapshot: snapshot)
                            pendingContextWindow = pending
                            settingContextWindow = true
                            Task {
                                defer { settingContextWindow = false }
                                do {
                                    guard let admission = model.authoritativeSnapshot(for: sessionID),
                                          admission.runtimeGeneration == snapshot.runtimeGeneration,
                                          admission.contextWindowPolicy?.model == policy.model else { return }
                                    let revision = try await model.setContextWindow(value, for: policy.model, sessionID: sessionID, expectedRevision: admission.revision, expectedRuntimeGeneration: admission.runtimeGeneration)
                                    pendingContextWindow = pendingContextWindow?.confirming(pending.id, revision: revision)
                                    if presentationActivity.allowsDataPublication { reconcile(presentationSource) }
                                } catch {
                                    pendingContextWindow = pendingContextWindow?.rejecting(pending.id)
                                    onError(error)
                                }
                            }
                        }
                    ),
                    limits: ContextWindowLimits(
                        minimum: policy.minimum,
                        maximum: policy.maximum,
                        default: policy.default,
                        longContextThreshold: nil
                    ),
                    inheritedValue: policy.default,
                    effectiveValue: pendingWindow.map { $0.value ?? policy.default } ?? policy.effective,
                    resetLabel: "Use configured default",
                    warning: policy.warning,
                    source: pendingWindow == nil ? policy.source : "pending",
                    accent: configurationRowAccent
                )
                .id("\(snapshot.runtimeGeneration):\(policy.model.contextWindowKey)")
                .disabled(lockedReason != nil || settingContextWindow || pendingModelSelection != nil || pendingThinking != nil)
            }
        } footer: {
            footer()
        }
    }

    private func reconcile(_ value: SessionContextPresentation?) {
        pendingModelSelection = SessionModelSelectionPresentation.reconciledPending(
            pending: pendingModelSelection,
            authoritative: value?.model,
            runtimeGeneration: value?.runtimeGeneration,
            revision: pendingConfigurationRevision
        )
        pendingContextWindow = pendingContextWindow?.reconciled(
            authoritative: value?.contextWindowPolicy?.override, snapshot: value, revision: pendingConfigurationRevision
        )
        pendingThinking = pendingThinking?.reconciled(
            authoritative: value?.thinkingLevel ?? "", snapshot: value, revision: pendingConfigurationRevision
        )
    }
}
