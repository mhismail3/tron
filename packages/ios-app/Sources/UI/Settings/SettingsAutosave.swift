import SwiftUI

/// Bind only user controls through this adapter. Installing projections and
/// switching scopes use the underlying state directly, so reads never write.
@MainActor
enum SettingsAutosave {
    static func binding<Draft: Equatable>(
        draft: Binding<Draft>, store: Binding<ScopedSettingsDraftStore<Draft>>,
        model: AppModel, target: SettingsTarget?, sessionID: String? = nil,
        admits: @escaping () -> Bool,
        patch: @escaping (Draft, Draft) -> JSONValue,
        settled: @escaping (Draft, SettingsTarget) -> Draft = { value, _ in value }
    ) -> Binding<Draft> {
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        let scopeGeneration = store.wrappedValue.scopeGeneration
        return Binding(get: { draft.wrappedValue }, set: { next in
            guard let target, admits(), model.profileRevision == profile,
                  model.configurationAutosave.inputGeneration == inputGeneration,
                  store.wrappedValue.scopeGeneration == scopeGeneration,
                  next != (store.wrappedValue.draft(for: target) ?? draft.wrappedValue) else { return }
            let previous = store.wrappedValue.draft(for: target) ?? draft.wrappedValue
            let delta = patch(next, previous)
            var drafts = store.wrappedValue
            drafts.update(next, for: target)
            let revision = drafts.revision(for: target)!
            let accepted = model.configurationAutosave.submit(
                key: .settings(target, sessionID: sessionID), patch: delta,
                write: { [weak model] patch in
                    guard let model, model.profileRevision == profile, let patch else { throw CancellationError() }
                    try await model.updateSettings(patch, target: target, sessionID: sessionID)
                },
                completed: { [weak model] in
                    guard let model, model.profileRevision == profile else { return }
                    let result = settled(next, target)
                    var current = store.wrappedValue
                    if current.markSaved(submitted: next, resulting: result, for: target, expectedRevision: revision) {
                        store.wrappedValue = current
                        if admits(), draft.wrappedValue == next { draft.wrappedValue = result }
                    }
                }
            )
            guard accepted else { return }
            store.wrappedValue = drafts
            draft.wrappedValue = next
        })
    }
}

extension View {
    func tronSettingsAutosave<Draft: Equatable>(
        draft: Binding<Draft>, store: Binding<ScopedSettingsDraftStore<Draft>>, initial: Draft
    ) -> some View {
        modifier(SettingsAutosaveLifetime(draft: draft, store: store, initial: initial))
    }
}

private struct SettingsAutosaveLifetime<Draft: Equatable>: ViewModifier {
    @Binding var draft: Draft
    @Binding var store: ScopedSettingsDraftStore<Draft>
    let initial: Draft
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .environment(\.tronSettingsInputScope, TronSettingsInputScope(
                profile: model.configurationAutosave.inputGeneration, scope: store.scopeGeneration
            ))
            .onChange(of: model.configurationAutosave.inputGeneration) { _, _ in
                store = ScopedSettingsDraftStore()
                draft = initial
            }
            .onSubmit { model.configurationAutosave.flush() }
            .onDisappear { model.configurationAutosave.flush() }
    }
}

/// Failures remain visible on re-entry, while successful autosave adds no
/// transient row or scroll movement. Retry is an explicit mutation intent.
struct SettingsAutosaveNotice: View {
    let key: ConfigurationAutosaveCoordinator.Key
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.configurationAutosave.error(for: key) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Changes not saved").font(TronTypography.bodySM)
                Text(error).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                if model.configurationAutosave.canRetry(key) {
                    Button { model.configurationAutosave.retry(key) } label: {
                        TronInlineActionLabel("Retry", icon: "arrow.clockwise", accent: .tronEmerald)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(accent: .tronSlate)
        }
    }
}
