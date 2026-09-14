import SwiftUI

/// Bounded Gateway projection for observations, links, and notes. iOS never
/// mirrors the canonical Knowledge corpus.
struct KnowledgeDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let onSelectDashboard: @MainActor (DashboardMode) -> Void
    let onOpenDraft: @MainActor (KnowledgeRecord) -> Void
    @State private var records: [KnowledgeRecord] = []
    @State private var selected: KnowledgeRecord?
    @State private var selectedIdentity: KnowledgePresentationIdentity?
    @State private var search = ""
    @State private var kind: KnowledgeRecordKind?
    @State private var scope: KnowledgeScope?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var nextCursor: String?
    @State private var loadingMore = false
    @State private var loadGeneration = 0
    @State private var configSheet = false
    @State private var connectorSheet = false
    @State private var importSheet = false
    @State private var captureSheet = false
    @State private var noteSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { Button("All Links") { kind = .source; scope = nil }.font(.caption.weight(kind == .source && scope == nil ? .bold : .regular)); Button("Observations") { kind = .observation; scope = nil }.font(.caption.weight(kind == .observation ? .bold : .regular)); Button("Personal") { scope = .personal; kind = nil }.font(.caption.weight(scope == .personal ? .bold : .regular)); Button("Research") { scope = .research; kind = nil }.font(.caption.weight(scope == .research ? .bold : .regular)) }.padding(.horizontal, 16).padding(.top, 8)
            HStack { Picker("Type", selection: $kind) { Text("All").tag(KnowledgeRecordKind?.none); ForEach(KnowledgeRecordKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.pickerStyle(.menu); Picker("Scope", selection: $scope) { Text("All scopes").tag(KnowledgeScope?.none); ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.pickerStyle(.menu); Spacer(); if revision > 0 { Text("r\(revision)").font(.caption).foregroundStyle(Color.tronTextSecondary) } }.padding(.horizontal, 16).padding(.vertical, 8)
            if let error { ContentUnavailableView("Knowledge unavailable", systemImage: "externaldrive.badge.xmark", description: Text(error)) }
            else if records.isEmpty && !loading { ContentUnavailableView("No knowledge yet", systemImage: "book.closed", description: Text("Observations, links, and notes retained by this Gateway will appear here.")) }
            else { List { ForEach(records) { record in Button { selected = record; selectedIdentity = model.knowledgePresentationIdentity } label: { KnowledgeRecordRow(record: record) }.buttonStyle(.plain).listRowBackground(Color.clear) }; if nextCursor != nil { Button(loadingMore ? "Loading…" : "Load more") { loadMore() }.frame(maxWidth: .infinity).listRowBackground(Color.clear) } }.listStyle(.plain).overlay { if loading { ProgressView() } } }
        }.background(Color.tronBackground).navigationTitle("Knowledge").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DashboardModeMenuButton(mode: .knowledge, onSelect: onSelectDashboard).frame(width: 34, height: 34) }; ToolbarItem(placement: .topBarTrailing) { Menu { Button("Observation configuration", systemImage: "eye") { configSheet = true }; Button("Connectors", systemImage: "arrow.triangle.2.circlepath") { connectorSheet = true }; Button("Capture URL", systemImage: "link.badge.plus") { captureSheet = true }; Button("New note", systemImage: "note.text.badge.plus") { noteSheet = true }; Button("Import legacy records", systemImage: "square.and.arrow.down") { importSheet = true } } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Knowledge actions") } }
        .searchable(text: $search, prompt: "Search Knowledge")
        .navigationDestination(item: $selected) { record in KnowledgeDetailView(record: record, origin: selectedIdentity ?? model.knowledgePresentationIdentity, onChanged: reload, onOpenDraft: openDraft) }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in records.removeAll(); selected = nil; selectedIdentity = nil; revision = 0; nextCursor = nil }
        .sheet(isPresented: $configSheet) { KnowledgeConfigurationView().environment(model) }
        .sheet(isPresented: $connectorSheet) { KnowledgeConnectorsView().environment(model) }
        .sheet(isPresented: $importSheet) { KnowledgeImportView().environment(model) }
        .sheet(isPresented: $captureSheet) { KnowledgeCaptureView { captureSheet = false; await reload() }.environment(model) }
        .sheet(isPresented: $noteSheet) { KnowledgeNoteCreateView { noteSheet = false; await reload() }.environment(model) }
        .task(id: "\(kind?.rawValue ?? "all")/\(scope?.rawValue ?? "all")/\(search)/\(activity.allowsPresentationPublication)/\(model.knowledgePresentationIdentity.profileID ?? "none")/\(model.knowledgePresentationIdentity.lifecycleGeneration ?? -1)/\(model.knowledgePresentationIdentity.connectionID ?? -1)") { guard activity.allowsPresentationPublication else { return }; await reload() }
        .refreshable { await reload() }
    }
    private func reload() async {
        loadGeneration += 1; let generation = loadGeneration; let identity = model.knowledgePresentationIdentity
        guard activity.allowsPresentationPublication, identity.profileID != nil, identity.lifecycleGeneration != nil else { return }
        loading = true; error = nil
        do {
            let response: KnowledgeListResponse
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { response = try await model.knowledge.list(kind: kind, scope: scope, limit: 50) }
            else { let found = try await model.knowledge.search(query: search, kind: kind, scope: scope, limit: 50); response = KnowledgeListResponse(records: found.hits.map { $0.record }, nextCursor: nil, stateRevision: found.stateRevision) }
            guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            records = response.records; nextCursor = response.nextCursor; revision = response.stateRevision
        } catch is CancellationError { return } catch { guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
        guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; loading = false
    }
    private func loadMore() {
        guard let cursor = nextCursor, !loadingMore, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loadingMore = true
        Task { @MainActor in
            let identity = model.knowledgePresentationIdentity
            do { let page = try await model.knowledge.list(kind: kind, scope: scope, cursor: cursor, limit: 50); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity, page.records.allSatisfy({ !records.contains($0) }) else { return }; records.append(contentsOf: page.records); nextCursor = page.nextCursor; revision = page.stateRevision; loadingMore = false }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription; loadingMore = false }
        }
    }
    private func openDraft(_ record: KnowledgeRecord) { guard model.knowledgePresentationIdentity == selectedIdentity ?? model.knowledgePresentationIdentity else { return }; selected = nil; onOpenDraft(record) }
}

private struct KnowledgeRecordRow: View {
    let record: KnowledgeRecord
    var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: record.kind.icon).foregroundStyle(Color.tronEmerald).frame(width: 24); VStack(alignment: .leading, spacing: 4) { Text(record.title).font(.headline).foregroundStyle(Color.tronTextPrimary).lineLimit(2); Text(record.summary).font(.subheadline).foregroundStyle(Color.tronTextSecondary).lineLimit(3); Text("\(record.kind.label) · \(record.scope.label) · \(record.updatedAt)").font(.caption).foregroundStyle(Color.tronTextSecondary).lineLimit(1) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.tronTextSecondary) }.padding(.vertical, 8).contentShape(Rectangle()) }
}

struct KnowledgeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onChanged: () async -> Void
    let onOpenDraft: (KnowledgeRecord) -> Void
    @State private var noteBody = ""
    @State private var editing = false
    @State private var message: String?
    @State private var forgetConfirmation = false
    @State private var correctionSheet = false
    private var admitsOrigin: Bool { model.knowledgePresentationIdentity == origin }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { Text(record.title).font(.title2.bold()); Label("\(record.kind.label) · \(record.scope.label)", systemImage: record.kind.icon).foregroundStyle(Color.tronEmerald); Text(record.summary).textSelection(.enabled); recordMetadata; sourceLink; noteMetadata; evidence; observationItems; if case .note(let note) = record.content, editing { TextEditor(text: $noteBody).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3))); Button("Save note") { saveNote(note) }.buttonStyle(.borderedProminent) }; if let message { Text(message).font(.footnote).foregroundStyle(Color.tronTextSecondary) } }.padding(20) }.background(Color.tronBackground).navigationTitle("Detail").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("Start editable session", systemImage: "plus.bubble") { onOpenDraft(record) }; if record.kind == .note { Button(editing ? "Cancel editing" : "Edit note", systemImage: "pencil") { editing.toggle(); if editing, case .note(let note) = record.content { noteBody = note.body ?? "" } } }; if record.kind == .source { Button("Assess with current interests", systemImage: "sparkles") { triage() } }; Button("Correct record", systemImage: "arrow.triangle.2.circlepath") { correctionSheet = true }; Button("Exclude from Knowledge", systemImage: "eye.slash") { exclude() }; Button("Forget permanently", systemImage: "trash", role: .destructive) { forgetConfirmation = true } } label: { Image(systemName: "ellipsis.circle") } } }.confirmationDialog("Forget this record?", isPresented: $forgetConfirmation) { Button("Forget", role: .destructive) { forget() } }.sheet(isPresented: $correctionSheet) { KnowledgeCorrectionView(record: record, origin: origin) { correctionSheet = false; dismiss() } } }
    @ViewBuilder private var recordMetadata: some View { VStack(alignment: .leading, spacing: 4) { Text("Revision: \(record.revisionId)").font(.caption); if let temporal = record.temporal { Text([temporal.eventAt, temporal.validFrom, temporal.validTo, temporal.reviewDue].compactMap { $0 }.joined(separator: " · ")).font(.caption) } }; if case .source(let source) = record.content { Text("Capture: \(source.captureDisposition.rawValue)").font(.caption) }; if case .note(let note) = record.content, let fields = note.fields { ForEach(Array(fields.enumerated()), id: \.offset) { _, field in Text("\(field.field): \(field.certainty.rawValue)").font(.caption) } } }
    @ViewBuilder private var sourceLink: some View { if case .source(let source) = record.content { if let uri = source.uri, let url = URL(string: uri) { Link(uri, destination: url).font(.callout) }; if let identity = source.identity { Text("\(identity.provider) · account \(identity.accountId) · item \(identity.itemId)").font(.caption).foregroundStyle(Color.tronTextSecondary) }; if let assessment = source.assessment { VStack(alignment: .leading, spacing: 6) { Text("Assessment").font(.headline); Text(assessment.summary); if let contribution = assessment.contribution { Text("Contribution: \(contribution)") }; if let use = assessment.possibleUse { Text("Possible use: \(use)") }; Text("Evidence \(assessment.evidenceQuality.rawValue) · Freshness \(assessment.freshness.rawValue)").font(.caption).foregroundStyle(Color.tronTextSecondary) } } } }
    private var evidence: some View { VStack(alignment: .leading, spacing: 8) { Text("Evidence").font(.headline); ForEach(Array(record.provenance.evidence.enumerated()), id: \.offset) { _, ref in Text(ref.sessionEntry.map { "Session \($0.sessionId) · entry \($0.entryId)" } ?? "Record \(ref.recordId ?? "object")").font(.footnote).foregroundStyle(Color.tronTextSecondary) } } }
    @ViewBuilder private var noteMetadata: some View { if case .note(let note) = record.content { if let freshness = note.freshness { Text("Freshness: \(freshness.rawValue)").font(.caption).foregroundStyle(Color.tronTextSecondary) }; if let contrary = note.contraryEvidence, !contrary.isEmpty { Text("Contrary evidence retained: \(contrary.count)").font(.caption).foregroundStyle(Color.tronAmber) } } }
    @ViewBuilder private var observationItems: some View { if case .observation(let observation) = record.content { VStack(alignment: .leading, spacing: 8) { Text("Observed items").font(.headline); Text("Entries \(observation.range.fromEntryId)…\(observation.range.toEntryId) · digest \(observation.range.entryDigest.prefix(12))…").font(.caption).foregroundStyle(Color.tronTextSecondary); ForEach(Array(observation.items.enumerated()), id: \.offset) { _, item in Text("\(item.attribution.rawValue.capitalized) · \(item.certainty.rawValue): \(item.text)").font(.callout) }; Button("Reflect bounded handoff") { reflect(observation) }.buttonStyle(.bordered) } } }
    private func reflect(_ observation: KnowledgeObservationContent) { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; Task { @MainActor in do { _ = try await model.knowledge.reflect(sessionID: observation.range.sessionId, sourceRevisionIDs: [record.revisionId], text: record.summary); guard admitsOrigin else { return }; message = "Reflected handoff updated." } catch { guard admitsOrigin else { return }; message = error.localizedDescription } } }
    private func triage() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; Task { @MainActor in do { let result = try await model.knowledge.triage(sourceID: record.id, expectedRevision: record.revisionId); guard admitsOrigin else { return }; message = "Assessment updated (\(result.assessment.freshness.rawValue))." } catch { guard admitsOrigin else { return }; message = error.localizedDescription } } }
    private func saveNote(_ note: KnowledgeNoteContent) { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; Task { @MainActor in do { _ = try await model.knowledge.updateNote(id: record.id, expectedRevision: record.revisionId, record: KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: .note, scope: record.scope, provenance: record.provenance, temporal: record.temporal, relations: record.relations, content: .note(KnowledgeNoteContent(title: note.title, body: noteBody, fields: note.fields, role: note.role, confirmed: note.confirmed, contraryEvidence: note.contraryEvidence, freshness: note.freshness, privacyScope: note.privacyScope)))); guard admitsOrigin else { return }; message = "Saved"; await onChanged() } catch { guard admitsOrigin else { return }; message = error.localizedDescription } } }
    private func exclude() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; Task { @MainActor in do { _ = try await model.knowledge.setExclusion(recordID: record.id, expectedRevision: record.revisionId, excluded: true); guard admitsOrigin else { return }; dismiss() } catch { guard admitsOrigin else { return }; message = error.localizedDescription } } }
    private func forget() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; Task { @MainActor in do { _ = try await model.knowledge.forget(id: record.id, expectedRevision: record.revisionId, reason: "Forgotten from iOS"); guard admitsOrigin else { return }; dismiss() } catch { guard admitsOrigin else { return }; message = error.localizedDescription } } }
}

struct KnowledgeConfigurationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var config: KnowledgeConfig?
    @State private var chosenModel: ModelRef?
    @State private var selectedSessionIDs = Set<String>()
    @State private var selectedProjectIDs = Set<String>()
    @State private var interestsText = ""
    @State private var error: String?
    @State private var identity: KnowledgePresentationIdentity?
    private var hasScope: Bool { !selectedSessionIDs.isEmpty || !selectedProjectIDs.isEmpty }
    private var canDisableOrSave: Bool { config?.observation.enabled == true || (chosenModel != nil && hasScope) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Observer") {
                    Toggle("Observe selected conversations", isOn: Binding(get: { config?.observation.enabled ?? false }, set: { config?.observation.enabled = $0 }))
                        .disabled(config?.observation.enabled != true && (chosenModel == nil || !hasScope))
                    Text(chosenModel.map { "Selected model: \($0.provider)/\($0.id)" } ?? "Choose an existing configured model before enabling observation.").font(.footnote).foregroundStyle(Color.tronTextSecondary)
                    ModelPicker(selection: $chosenModel, models: model.providerCatalog(for: .global)?.models.filter { $0.available } ?? []).frame(minHeight: 160)
                }
                Section("Current interests") { TextEditor(text: $interestsText).frame(minHeight: 100); Text("One interest per line, up to 50. Interests guide source triage and do not enable observation.").font(.footnote).foregroundStyle(Color.tronTextSecondary) }
                Section("Existing sessions") {
                    if model.sessions.isEmpty { Text("No sessions are available on this Gateway.").font(.footnote).foregroundStyle(Color.tronTextSecondary) }
                    ForEach(model.sessions.prefix(100)) { session in
                        Toggle(session.title, isOn: Binding(get: { selectedSessionIDs.contains(session.id) }, set: { if $0 { selectedSessionIDs.insert(session.id) } else { selectedSessionIDs.remove(session.id) } }))
                    }
                }
                Section("Existing projects") {
                    if let workspace = model.workspace { ForEach(workspace.entries.filter { $0.kind == .directory }.prefix(100)) { entry in Toggle(entry.name, isOn: Binding(get: { selectedProjectIDs.contains(entry.path) }, set: { if $0 { selectedProjectIDs.insert(entry.path) } else { selectedProjectIDs.remove(entry.path) } })) } }
                    Text("An empty allowlist means no eligible scope. Select at least one existing session or project; exclusions override these choices.").font(.footnote).foregroundStyle(Color.tronTextSecondary)
                    if !hasScope { Label("No scope selected", systemImage: "exclamationmark.triangle").foregroundStyle(Color.tronAmber) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Observation configuration")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(config == nil || !canDisableOrSave) } }
            .task { await load() }
        }
    }
    private func load() async {
        do {
            let requestIdentity = model.knowledgePresentationIdentity
            let loaded = try await model.knowledge.status()
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity, requestIdentity.profileID != nil else { return }
            identity = requestIdentity; config = loaded.config; interestsText = loaded.config.currentInterests.joined(separator: "\n"); selectedSessionIDs = Set(loaded.config.eligibility.sessionIds); selectedProjectIDs = Set(loaded.config.eligibility.projectIds)
            if let value = loaded.config.observation.model { let parts = value.split(separator: "/", maxSplits: 1).map(String.init); if parts.count == 2 { chosenModel = ModelRef(provider: parts[0], id: parts[1]) } }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard var config else { return }
        guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { error = "Gateway changed; reopen configuration."; return }
        if config.observation.enabled && (chosenModel == nil || !hasScope) { error = "Select a model and at least one scope before enabling observation."; return }
        if let chosenModel { config.observation.model = chosenModel.contextWindowKey }
        config.eligibility.sessionIds = selectedSessionIDs.sorted(); config.eligibility.projectIds = selectedProjectIDs.sorted(); config.currentInterests = interestsText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50).map { String($0.prefix(500)) }
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        Task { @MainActor in do { _ = try await model.knowledge.configure(config); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; dismiss() } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; self.error = error.localizedDescription } }
    }
}

struct KnowledgeConnectorsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnowledgePresentationIdentity?
    @State private var statuses: [String: KnowledgeConnectorStatus] = [:]
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List(["raindrop", "x"], id: \.self) { connector in
                VStack(alignment: .leading, spacing: 8) {
                    Label(connector == "x" ? "X" : "Raindrop", systemImage: "link").font(.headline)
                    Text(statuses[connector]?.detail ?? "Checking status…").font(.footnote).foregroundStyle(Color.tronTextSecondary)
                    if statuses[connector]?.writesEnabled == false { Text("Remote writes disabled").font(.caption).foregroundStyle(Color.tronAmber) }
                    HStack { Button("Refresh") { refresh(connector) }.buttonStyle(.bordered); Button("Configure") { configure(connector) }.buttonStyle(.bordered).disabled(statuses[connector]?.available == false); Button("Run") { run(connector) }.buttonStyle(.borderedProminent).disabled(statuses[connector]?.configured != true) }
                }.padding(.vertical, 8)
            }
            .navigationTitle("Connectors")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { refresh("raindrop"); refresh("x") }
            .alert("Connector", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
        }
    }
    private func refresh(_ connector: String) { guard activity.allowsPresentationPublication else { return }; let requestIdentity = model.knowledgePresentationIdentity; Task { @MainActor in do { let status = try await model.knowledge.connectorStatus(connector); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; identity = requestIdentity; statuses[connector] = status } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; statuses[connector] = KnowledgeConnectorStatus(connector: connector, available: false, configured: false, enabled: false, writesEnabled: false, state: "unavailable", detail: error.localizedDescription, lastRunAt: nil) } } }
    private func configure(_ connector: String) { guard activity.allowsPresentationPublication else { return }; let requestIdentity = identity ?? model.knowledgePresentationIdentity; Task { @MainActor in do { let status = try await model.knowledge.configureConnector(connector, enabled: true); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; statuses[connector] = status } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription } } }
    private func run(_ connector: String) { guard let status = statuses[connector], status.configured, activity.allowsPresentationPublication else { return }; let requestIdentity = identity ?? model.knowledgePresentationIdentity; Task { @MainActor in do { let result = try await model.knowledge.runConnector(connector, dryRun: false); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = result.detail ?? "Run accepted." } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription } } }
}

struct KnowledgeImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var plan: KnowledgeImportPlan?
    @State private var message: String?
    @State private var confirmExecute = false
    @State private var identity: KnowledgePresentationIdentity?
    var body: some View {
        NavigationStack {
            Form {
                Section("Read-only dry run") { TextField("Authorized source path", text: $path).textInputAutocapitalization(.never); Button("Inspect import") { dryRun() }.disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                if let plan { Section("Inspected plan") { LabeledContent("Items", value: "\(plan.total)"); LabeledContent("Accepted", value: "\(plan.accepted)"); LabeledContent("Skipped", value: "\(plan.skipped)"); Text("Plan hash: \(plan.planHash)").font(.caption).textSelection(.enabled); Button("Import accepted items") { confirmExecute = true } } }
                if let message { Text(message).foregroundStyle(Color.tronTextSecondary) }
            }.navigationTitle("Import Knowledge").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Execute this exact inspected import?", isPresented: $confirmExecute) { Button("Import", role: .destructive) { if let plan { execute(plan) } }; Button("Cancel", role: .cancel) {} }
        }
    }
    private func dryRun() { guard activity.allowsPresentationPublication else { return }; let source = path; let requestIdentity = model.knowledgePresentationIdentity; Task { @MainActor in do { let value = try await model.knowledge.importDryRun(source: source); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; identity = requestIdentity; plan = value; message = nil } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription } } }
    private func execute(_ plan: KnowledgeImportPlan) { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { message = "Gateway changed; inspect the source again."; return }; let requestIdentity = identity ?? model.knowledgePresentationIdentity; Task { @MainActor in do { let value = try await model.knowledge.importRun(source: plan.source, planHash: plan.planHash); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = value.detail ?? "Import complete." } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription } } }
}

private struct KnowledgeCorrectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onComplete: () -> Void
    @State private var text: String
    @State private var error: String?

    init(record: KnowledgeRecord, origin: KnowledgePresentationIdentity, onComplete: @escaping () -> Void) {
        self.record = record; self.origin = origin; self.onComplete = onComplete
        _text = State(initialValue: record.summary)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Correction") { TextEditor(text: $text).frame(minHeight: 180); Text("This creates a new immutable revision and preserves the original as corrected evidence.").font(.footnote).foregroundStyle(Color.tronTextSecondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Correct Knowledge")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }
    }
    private func save() {
        guard model.knowledgePresentationIdentity == origin else { error = "Gateway changed; reopen this entry."; return }
        let replacement = KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: record.kind, scope: record.scope, provenance: record.provenance, temporal: record.temporal, relations: record.relations, content: correctedContent)
        let relation = KnowledgeRelation(type: .corrects, recordId: record.id, revisionId: record.revisionId, field: nil)
        Task { @MainActor in do { _ = try await model.knowledge.correct(id: record.id, expectedRevision: record.revisionId, replacement: replacement, relation: relation); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; onComplete() } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; self.error = error.localizedDescription } }
    }
    private var correctedContent: KnowledgeRecordContent {
        switch record.content {
        case .source(let value): return .source(KnowledgeSourceContent(title: value.title, uri: value.uri, text: text, object: value.object, mediaType: value.mediaType, captureDisposition: value.captureDisposition, annotations: value.annotations, sourcePublishedAt: value.sourcePublishedAt, capturedAt: value.capturedAt, origin: value.origin, origins: value.origins, identity: value.identity, assessment: value.assessment))
        case .observation(let value): return .observation(KnowledgeObservationContent(range: value.range, items: [KnowledgeObservationItem(text: text, attribution: .user, observedAt: value.items.first?.observedAt ?? record.updatedAt, certainty: .qualified, evidence: value.items.first?.evidence, field: nil)], observer: value.observer))
        case .note(let value): return .note(KnowledgeNoteContent(title: value.title, body: text, fields: value.fields, role: value.role, confirmed: value.confirmed, contraryEvidence: value.contraryEvidence, freshness: value.freshness, privacyScope: value.privacyScope))
        }
    }
}

private struct KnowledgeCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var uri = ""
    @State private var scope: KnowledgeScope = .research
    @State private var error: String?
    var body: some View {
        NavigationStack { Form {
            Section("Manual URL") { TextField("Title", text: $title); TextField("https://…", text: $uri).textInputAutocapitalization(.never).keyboardType(.URL); Picker("Scope", selection: $scope) { ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.label).tag($0) } }; Text("The Gateway performs bounded safe fetching and records capture quality.").font(.footnote).foregroundStyle(Color.tronTextSecondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Capture URL").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Capture") { capture() }.disabled(!valid) } } }
    }
    private var valid: Bool { guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased()), url.user == nil, url.password == nil else { return false }; return true }
    private func capture() { guard valid else { error = "Use an http(s) URL without credentials."; return }; let identity = model.knowledgePresentationIdentity; let record = KnowledgeRecordDraft(id: nil, createdAt: nil, updatedAt: nil, kind: .source, scope: scope, provenance: KnowledgeProvenance(actor: .user, source: "ios-manual", sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [], content: .source(KnowledgeSourceContent(title: title, uri: uri, text: nil, object: nil, mediaType: nil, captureDisposition: .metadataOnly, annotations: nil, sourcePublishedAt: nil, capturedAt: ISO8601DateFormatter().string(from: Date()), origin: "manual", origins: nil, identity: nil, assessment: nil)))
        Task { @MainActor in do { _ = try await model.knowledge.captureSource(record); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; await onComplete(); dismiss() } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription } }
    }
}

private struct KnowledgeNoteCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var noteText = ""
    @State private var scope: KnowledgeScope = .personal
    @State private var role: KnowledgeNoteRole = .fact
    @State private var confirmed = false
    @State private var error: String?
    var body: some View {
        NavigationStack { Form {
            Section("Note") { TextField("Title", text: $title); TextEditor(text: $noteText).frame(minHeight: 140); Picker("Role", selection: $role) { ForEach(KnowledgeNoteRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }; Picker("Scope", selection: $scope) { ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.label).tag($0) } }; Toggle("Confirmed by me", isOn: $confirmed) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("New Note").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }
    }
    private func save() { let identity = model.knowledgePresentationIdentity; let record = KnowledgeRecordDraft(id: nil, createdAt: nil, updatedAt: nil, kind: .note, scope: scope, provenance: KnowledgeProvenance(actor: .user, source: "ios-note", sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [], content: .note(KnowledgeNoteContent(title: title, body: noteText.isEmpty ? nil : noteText, fields: nil, role: role, confirmed: confirmed, contraryEvidence: nil, freshness: .current, privacyScope: "private")))
        Task { @MainActor in do { _ = try await model.knowledge.createNote(record); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; await onComplete(); dismiss() } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription } }
    }
}
