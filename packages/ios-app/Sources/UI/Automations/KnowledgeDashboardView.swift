import SwiftUI

/// Catalogue pagination is available only for list responses. Search responses
/// are intentionally bounded to one Gateway result page.
enum KnowledgeCatalogPaginationPolicy {
    static func admits(cursor: String?, search: String, loadingMore: Bool) -> Bool {
        cursor != nil && !loadingMore && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum KnowledgeImportPresentationPolicy {
    static func corpusProgress(planned: Int, selected: Int, offset: Int) -> String {
        "\(min(max(0, planned), max(0, offset) + max(0, selected))) of \(max(0, planned))"
    }

    static func completionMessage(plan: KnowledgeImportPlan, result: KnowledgeImportResult, offset: Int) -> String {
        let processed = result.imported + result.resumed + result.skipped
        let end = min(plan.planned, max(0, offset) + plan.selected)
        guard result.failed == 0, processed == plan.selected else {
            return "Import incomplete for this batch (\(processed) of \(plan.selected) admitted; \(result.failed) failed); inspect it again before continuing."
        }
        if end < plan.planned {
            return "Batch complete (through \(end) of \(plan.planned)); inspect the next batch to continue."
        }
        if result.completed { return "Import complete (\(result.imported) imported)." }
        return "Import paused (\(result.progress.remaining) remaining)."
    }
}

/// Bounded Gateway projection for observations, links, and notes. iOS never
/// mirrors the canonical Knowledge corpus.
struct KnowledgeDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let onSelectDashboard: @MainActor (DashboardMode) -> Void
    let onOpenDraft: @MainActor (KnowledgeRecord) -> Void
    let onOpenSession: @MainActor (String, String) -> Void
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
    @State private var status: KnowledgeStatus?
    @State private var coverage: [KnowledgeObservationCoverage] = []
    @State private var loadGeneration = 0
    @State private var linkedRecordGeneration = 0
    @State private var configSheet = false
    @State private var connectorSheet = false
    @State private var importSheet = false
    @State private var captureSheet = false
    @State private var noteSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { Button("All Links") { kind = .source; scope = nil }.font(.caption.weight(kind == .source && scope == nil ? .bold : .regular)); Button("Observations") { kind = .observation; scope = nil }.font(.caption.weight(kind == .observation ? .bold : .regular)); Button("Personal") { scope = .personal; kind = nil }.font(.caption.weight(scope == .personal ? .bold : .regular)); Button("Research") { scope = .research; kind = nil }.font(.caption.weight(scope == .research ? .bold : .regular)) }.padding(.horizontal, 16).padding(.top, 8)
            HStack { Picker("Type", selection: $kind) { Text("All").tag(KnowledgeRecordKind?.none); ForEach(KnowledgeRecordKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.pickerStyle(.menu); Picker("Scope", selection: $scope) { Text("All scopes").tag(KnowledgeScope?.none); ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.pickerStyle(.menu); Spacer(); if revision > 0 { Text("r\(revision)").font(.caption).foregroundStyle(Color.tronTextSecondary) } }.padding(.horizontal, 16).padding(.vertical, 8)
            if let status { coverageSummary(status) }
            if let error { ContentUnavailableView("Knowledge unavailable", systemImage: "externaldrive.badge.xmark", description: Text(error)) }
            else if records.isEmpty && !loading { ContentUnavailableView("No knowledge yet", systemImage: "book.closed", description: Text("Observations, links, and notes retained by this Gateway will appear here.")) }
            else { List { ForEach(records) { record in Button { selected = record; selectedIdentity = model.knowledgePresentationIdentity } label: { KnowledgeRecordRow(record: record) }.buttonStyle(.plain).listRowBackground(Color.clear) }; if nextCursor != nil { Button(loadingMore ? "Loading…" : "Load more") { loadMore() }.frame(maxWidth: .infinity).listRowBackground(Color.clear) } }.listStyle(.plain).overlay { if loading { ProgressView() } } }
        }.background(Color.tronBackground).navigationTitle("Knowledge").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { DashboardModeMenuButton(mode: .knowledge, onSelect: onSelectDashboard).frame(width: 34, height: 34) }; ToolbarItem(placement: .topBarTrailing) { Menu { Button("Observation configuration", systemImage: "eye") { configSheet = true }; Button("Connectors", systemImage: "arrow.triangle.2.circlepath") { connectorSheet = true }; Button("Capture URL", systemImage: "link.badge.plus") { captureSheet = true }; Button("New note", systemImage: "note.text.badge.plus") { noteSheet = true }; Button("Import legacy records", systemImage: "square.and.arrow.down") { importSheet = true } } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Knowledge actions") } }
        .searchable(text: $search, prompt: "Search Knowledge")
        .navigationDestination(item: $selected) { record in KnowledgeDetailView(record: record, origin: selectedIdentity ?? model.knowledgePresentationIdentity, onChanged: reload, onOpenDraft: openDraft, onOpenSession: onOpenSession, onOpenRecord: openLinkedRecord) }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in
            // Retire both the visible page and any manually spawned page task;
            // the next task must carry the new Gateway identity from its start.
            loadGeneration += 1
            loadingMore = false
            records.removeAll(); selected = nil; selectedIdentity = nil; revision = 0; nextCursor = nil; status = nil; coverage.removeAll(); error = nil
        }
        .sheet(isPresented: $configSheet) { KnowledgeConfigurationView().environment(model) }
        .sheet(isPresented: $connectorSheet) { KnowledgeConnectorsView().environment(model) }
        .sheet(isPresented: $importSheet) { KnowledgeImportView().environment(model) }
        .sheet(isPresented: $captureSheet) { KnowledgeCaptureView { captureSheet = false; await reload() }.environment(model) }
        .sheet(isPresented: $noteSheet) { KnowledgeNoteCreateView { noteSheet = false; await reload() }.environment(model) }
        .task(id: "\(kind?.rawValue ?? "all")/\(scope?.rawValue ?? "all")/\(search)/\(activity.allowsPresentationPublication)/\(model.knowledgePresentationIdentity.profileID ?? "none")/\(model.knowledgePresentationIdentity.lifecycleGeneration ?? -1)/\(model.knowledgePresentationIdentity.connectionID ?? -1)") { guard activity.allowsPresentationPublication else { return }; await reload() }
        .refreshable { await reload() }
    }
    @ViewBuilder
    private func coverageSummary(_ status: KnowledgeStatus) -> some View {
        let coverage = status.coverage
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Observation coverage", systemImage: "eye")
                    .font(.headline)
                Spacer()
                Text("\(coverage.observedCount + coverage.emptyCount + coverage.excludedCount) settled")
                    .font(.caption).foregroundStyle(Color.tronTextSecondary)
            }
            Text("Observed \(coverage.observedCount) · Empty \(coverage.emptyCount) · Excluded \(coverage.excludedCount)")
                .font(.caption).foregroundStyle(Color.tronTextSecondary)
            if coverage.remainingCount > 0 {
                Label("\(coverage.remainingCount) cuts need attention (pending \(coverage.pendingCount), failed \(coverage.failedCount), unavailable \(coverage.unavailableCount))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.tronAmber)
                ForEach(self.coverage.filter { $0.disposition == .pending || $0.disposition == .failed || $0.disposition == .unavailable }) { cut in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(cut.disposition.rawValue.capitalized) · \(cut.id)").font(.caption.bold())
                            Text("\(cut.range.fromEntryId)…\(cut.range.toEntryId) · \(cut.reason ?? "No reason recorded")").font(.caption2).foregroundStyle(Color.tronTextSecondary)
                        }
                        Spacer()
                        Button("Open") { onOpenSession(cut.range.sessionId, cut.range.fromEntryId) }.font(.caption)
                    }
                }
            } else {
                Text("No pending, failed, or unavailable observation cuts.")
                    .font(.caption).foregroundStyle(Color.tronTextSecondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.tronBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Observation coverage. Observed \(coverage.observedCount), empty \(coverage.emptyCount), excluded \(coverage.excludedCount), remaining \(coverage.remainingCount)")
    }

    private func reload() async {
        loadGeneration += 1; let generation = loadGeneration; let identity = model.knowledgePresentationIdentity
        guard activity.allowsPresentationPublication, identity.profileID != nil, identity.lifecycleGeneration != nil else { return }
        loading = true; error = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            async let loadedStatus = model.knowledge.status()
            async let loadedCoverage = model.knowledge.coverage(limit: 50)
            let response: KnowledgeListResponse
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { response = try await model.knowledge.list(kind: kind, scope: scope, limit: 50) }
            else { let found = try await model.knowledge.search(query: search, kind: kind, scope: scope, limit: 50); response = KnowledgeListResponse(records: found.hits.map { $0.record }, nextCursor: nil, stateRevision: found.stateRevision) }
            let currentStatus = try await loadedStatus
            let currentCoverage = try await loadedCoverage
            guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            records = response.records; nextCursor = response.nextCursor; revision = response.stateRevision; status = currentStatus; coverage = currentCoverage.coverage
        } catch is CancellationError { return } catch { guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
    }
    private func loadMore() {
        guard KnowledgeCatalogPaginationPolicy.admits(cursor: nextCursor, search: search, loadingMore: loadingMore), let cursor = nextCursor else { return }
        loadingMore = true
        let generation = loadGeneration
        let query = search
        let requestedKind = kind
        let requestedScope = scope
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            defer { if generation == loadGeneration { loadingMore = false } }
            guard generation == loadGeneration, query == search, requestedKind == kind, requestedScope == scope,
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            do {
                let page = try await model.knowledge.list(kind: requestedKind, scope: requestedScope, cursor: cursor, limit: 50)
                guard generation == loadGeneration, query == search, requestedKind == kind, requestedScope == scope,
                      activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                      page.records.allSatisfy({ !records.contains($0) }) else { return }
                records.append(contentsOf: page.records); nextCursor = page.nextCursor; revision = page.stateRevision
            } catch is CancellationError { return }
            catch { guard generation == loadGeneration, query == search, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
        }
    }
    private func openDraft(_ record: KnowledgeRecord) { guard model.knowledgePresentationIdentity == selectedIdentity ?? model.knowledgePresentationIdentity else { return }; selected = nil; onOpenDraft(record) }
    private func openLinkedRecord(id: String, revisionID: String?) {
        guard let selectedIdentity, model.knowledgePresentationIdentity == selectedIdentity, activity.allowsPresentationPublication else { return }
        linkedRecordGeneration &+= 1
        let generation = linkedRecordGeneration
        let identity = selectedIdentity
        Task { @MainActor in
            guard generation == linkedRecordGeneration, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == identity else { return }
            do {
                let linked = try await model.knowledge.read(id: id, revisionID: revisionID)
                guard generation == linkedRecordGeneration, activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == identity else { return }
                guard let linked else { self.error = "Linked record is unavailable, excluded, or forgotten. Refresh Knowledge and retry the citation."; return }
                selected = linked
                self.selectedIdentity = identity
            } catch is CancellationError { return }
            catch { guard generation == linkedRecordGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
        }
    }
}

private struct KnowledgeRecordRow: View {
    let record: KnowledgeRecord
    var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: record.kind.icon).foregroundStyle(Color.tronEmerald).frame(width: 24); VStack(alignment: .leading, spacing: 4) { Text(record.title).font(.headline).foregroundStyle(Color.tronTextPrimary).lineLimit(2); Text(record.summary).font(.subheadline).foregroundStyle(Color.tronTextSecondary).lineLimit(3); Text("\(record.kind.label) · \(record.scope.label) · \(record.updatedAt)").font(.caption).foregroundStyle(Color.tronTextSecondary).lineLimit(1) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.tronTextSecondary) }.padding(.vertical, 8).contentShape(Rectangle()) }
}

struct KnowledgeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onChanged: () async -> Void
    let onOpenDraft: (KnowledgeRecord) -> Void
    let onOpenSession: (String, String) -> Void
    let onOpenRecord: (String, String?) -> Void
    @State private var noteBody = ""
    @State private var editing = false
    @State private var message: String?
    @State private var forgetConfirmation = false
    @State private var correctionSheet = false
    @State private var evidenceMessage: String?
    @State private var objectBytes = Data()
    @State private var objectNextOffset: Int?
    @State private var objectTotalBytes: Int?
    @State private var objectLoading = false
    @State private var reflectedHandoff: KnowledgeRecord?
    @State private var objectRequestGeneration = 0
    @State private var reflectionRequestGeneration = 0
    private var admitsOrigin: Bool { model.knowledgePresentationIdentity == origin && activity.allowsPresentationPublication }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { Text(record.title).font(.title2.bold()); Label("\(record.kind.label) · \(record.scope.label)", systemImage: record.kind.icon).foregroundStyle(Color.tronEmerald); Text(record.summary).textSelection(.enabled); recordMetadata; sourceLink; noteMetadata; evidence; observationItems; if let reflectedHandoff { VStack(alignment: .leading, spacing: 8) { Text("Generated reflected handoff").font(.headline); Text(reflectedHandoff.summary).font(.callout).textSelection(.enabled); Button("Start editable session from handoff") { onOpenDraft(reflectedHandoff) }.buttonStyle(.bordered) } }; if case .note(let note) = record.content, editing { TextEditor(text: $noteBody).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3))); Button("Save note") { saveNote(note) }.buttonStyle(.borderedProminent) }; if let message { Text(message).font(.footnote).foregroundStyle(Color.tronTextSecondary) } }.padding(20) }.background(Color.tronBackground).navigationTitle("Detail").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("Start editable session", systemImage: "plus.bubble") { onOpenDraft(record) }; if record.kind == .note { Button(editing ? "Cancel editing" : "Edit note", systemImage: "pencil") { editing.toggle(); if editing, case .note(let note) = record.content { noteBody = note.body ?? "" } } }; if record.kind == .source { Button("Assess with current interests", systemImage: "sparkles") { triage() } }; Button("Correct record", systemImage: "arrow.triangle.2.circlepath") { correctionSheet = true }; Button("Exclude from Knowledge", systemImage: "eye.slash") { exclude() }; Button("Forget permanently", systemImage: "trash", role: .destructive) { forgetConfirmation = true } } label: { Image(systemName: "ellipsis.circle") } } }.confirmationDialog("Forget this record?", isPresented: $forgetConfirmation) { Button("Forget", role: .destructive) { forget() } }.sheet(isPresented: $correctionSheet) { KnowledgeCorrectionView(record: record, origin: origin) { correctionSheet = false; await onChanged(); dismiss() } } }
    @ViewBuilder private var recordMetadata: some View { VStack(alignment: .leading, spacing: 6) { Text("Revision: \(record.revisionId)").font(.caption); if let temporal = record.temporal { Text([temporal.eventAt.map { "event \($0)" }, temporal.validFrom.map { "valid from \($0)" }, temporal.validTo.map { "valid to \($0)" }, temporal.reviewDue.map { "review \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption) } }; if case .source(let source) = record.content { Text("Capture: \(source.captureDisposition.rawValue)").font(.caption); if source.captureDisposition != .complete { Label("Evidence is \(source.captureDisposition.rawValue); generated text is not proof.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.tronAmber) } }; if case .note(let note) = record.content, let fields = note.fields { VStack(alignment: .leading, spacing: 8) { Text("Structured qualifications").font(.headline); ForEach(Array(fields.enumerated()), id: \.offset) { _, field in VStack(alignment: .leading, spacing: 3) { Text(field.field).font(.subheadline.bold()); Text("Value: \(jsonText(field.value))").font(.callout); if let subject = field.subject { Text("Subject: \(subject)").font(.caption) }; Text("\(field.certainty.rawValue)\(field.validFrom.map { " · from \($0)" } ?? "")\(field.validTo.map { " · to \($0)" } ?? "")").font(.caption).foregroundStyle(Color.tronTextSecondary); citationLinks(field.evidence) } } } } }
    @ViewBuilder private var sourceLink: some View { if case .source(let source) = record.content { if let uri = source.uri, let url = URL(string: uri) { Link(uri, destination: url).font(.callout) }; if let object = source.object {
            Button(objectBytes.isEmpty ? "Open retained source object (\(object.bytes) bytes)" : "Load retained source object") { readObject(object, offset: objectNextOffset ?? 0) }.buttonStyle(.bordered).disabled(objectLoading || objectNextOffset == nil && !objectBytes.isEmpty)
            if objectLoading { ProgressView().controlSize(.small) }
            if !objectBytes.isEmpty {
                Text(String(data: objectBytes, encoding: .utf8) ?? "Binary source object (\(objectBytes.count) bytes loaded)").font(.footnote.monospaced()).textSelection(.enabled)
                if let next = objectNextOffset { Text("Loaded \(objectBytes.count) of \(objectTotalBytes ?? object.bytes) bytes.").font(.caption).foregroundStyle(Color.tronTextSecondary); Button("Load next chunk (offset \(next))") { readObject(object, offset: next) }.buttonStyle(.bordered) }
                else { Text("Complete retained object loaded (\(objectBytes.count) bytes).").font(.caption).foregroundStyle(Color.tronTextSecondary) }
            }
            if let retention = source.retention { Text("Retention: \(retention.sensitivity) · evidence \(retention.evidenceAvailable ? "available" : "unavailable")").font(.caption).foregroundStyle(Color.tronTextSecondary) }
        }; if let representations = source.representations, !representations.isEmpty { VStack(alignment: .leading, spacing: 6) { Text("Retained representations").font(.headline); ForEach(Array(representations.enumerated()), id: \.offset) { _, representation in Button("Open \(representation.kind == .providerAPI ? "provider API" : "linked article") representation (\(representation.object.bytes) bytes)") { readObject(representation.object, offset: 0) }.font(.callout).disabled(objectLoading) } } }; if let annotations = source.annotations, !annotations.isEmpty { VStack(alignment: .leading, spacing: 5) { Text("Annotations and corrections").font(.headline); ForEach(Array(annotations.enumerated()), id: \.offset) { _, annotation in Text(annotation.text).font(.callout).textSelection(.enabled) } } }; if let identity = source.identity { Text("\(identity.provider) · account \(identity.accountId) · item \(identity.itemId)").font(.caption).foregroundStyle(Color.tronTextSecondary) }; if let assessment = source.assessment { VStack(alignment: .leading, spacing: 6) { Text("Assessment").font(.headline); Text(assessment.summary); if let contribution = assessment.contribution { Text("Contribution: \(contribution)") }; if let use = assessment.possibleUse { Text("Possible use: \(use)") }; Text("Evidence \(assessment.evidenceQuality.rawValue) · Freshness \(assessment.freshness.rawValue)").font(.caption).foregroundStyle(Color.tronTextSecondary) } } } }
    private var evidence: some View { VStack(alignment: .leading, spacing: 8) { Text("Evidence").font(.headline); citationLinks(record.provenance.evidence); if case .observation(let observation) = record.content { ForEach(Array(observation.items.enumerated()), id: \.offset) { _, item in citationLinks(item.evidence ?? []) } }; if case .note(let note) = record.content, let contrary = note.contraryEvidence { Text("Contrary evidence").font(.subheadline.bold()).foregroundStyle(Color.tronAmber); citationLinks(contrary) }; if let evidenceMessage { Text(evidenceMessage).font(.footnote).foregroundStyle(Color.tronTextSecondary) } } }
    @ViewBuilder private func citationLinks(_ refs: [KnowledgeEvidenceRef]) -> some View { ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in if let citation = ref.sessionEntry { Button("Open originating session · \(citation.entryId)") { openSessionEvidence(citation) }.font(.footnote) } else if let recordID = ref.recordId { Button("Open record \(recordID) · revision \(ref.revisionId ?? "latest")") { onOpenRecord(recordID, ref.revisionId) }.font(.footnote) } else if let hash = ref.objectHash { Text("Retained object \(hash.prefix(12))…").font(.footnote).foregroundStyle(Color.tronTextSecondary) } else { Text("Evidence unavailable").font(.footnote).foregroundStyle(Color.tronAmber) } } }
    private func jsonText(_ value: JSONValue) -> String { switch value { case .string(let value): return value; case .number(let value): return String(value); case .bool(let value): return value ? "true" : "false"; case .null: return "null"; case .array(let values): return "[\(values.prefix(20).map(jsonText).joined(separator: ", "))]"; case .object(let values): return "{\(values.keys.sorted().prefix(20).compactMap { key in values[key].map { "\(key): \(jsonText($0))" } }.joined(separator: ", "))}" } }
    @ViewBuilder private var noteMetadata: some View { if case .note(let note) = record.content { if let freshness = note.freshness { Text("Freshness: \(freshness.rawValue)").font(.caption).foregroundStyle(Color.tronTextSecondary) }; if let contrary = note.contraryEvidence, !contrary.isEmpty { Text("Contrary evidence retained: \(contrary.count)").font(.caption).foregroundStyle(Color.tronAmber) } } }
    @ViewBuilder private var observationItems: some View { if case .observation(let observation) = record.content { VStack(alignment: .leading, spacing: 8) { Text("Observed items").font(.headline); Text("Entries \(observation.range.fromEntryId)…\(observation.range.toEntryId) · digest \(observation.range.entryDigest.prefix(12))…").font(.caption).foregroundStyle(Color.tronTextSecondary); ForEach(Array(observation.items.enumerated()), id: \.offset) { _, item in Text("\(item.attribution.rawValue.capitalized) · \(item.certainty.rawValue): \(item.text)").font(.callout) }; Button("Reflect bounded handoff") { reflect(observation) }.buttonStyle(.bordered) } } }
    private func readObject(_ reference: KnowledgeObjectRef, offset: Int) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
        objectRequestGeneration &+= 1
        let requestGeneration = objectRequestGeneration
        let requestIdentity = origin
        objectLoading = true
        let requestedOffset = max(0, offset)
        Task { @MainActor in
            guard requestGeneration == objectRequestGeneration, model.knowledgePresentationIdentity == requestIdentity,
                  activity.allowsPresentationPublication else { return }
            do {
                let object = try await model.knowledge.readObject(reference, offset: requestedOffset)
                guard requestGeneration == objectRequestGeneration, model.knowledgePresentationIdentity == requestIdentity,
                      activity.allowsPresentationPublication else { return }
                objectLoading = false
                guard let object, let bytes = Data(base64Encoded: object.base64) else { evidenceMessage = "Retained object is unavailable or excluded."; return }
                if requestedOffset == 0 { objectBytes = bytes } else if requestedOffset == objectBytes.count { objectBytes.append(bytes) } else { evidenceMessage = "The retained object changed while it was being read; reopen this entry."; return }
                objectTotalBytes = object.totalBytes; objectNextOffset = object.nextOffset
                evidenceMessage = "Retained object chunk verified (\(object.bytes) of \(object.totalBytes ?? object.bytes) bytes, \(object.mediaType))."
            } catch is CancellationError { return }
            catch { guard requestGeneration == objectRequestGeneration, model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; objectLoading = false; evidenceMessage = error.localizedDescription }
        }
    }
    private func openSessionEvidence(_ citation: KnowledgeSessionEntryCitation) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
        onOpenSession(citation.sessionId, citation.entryId)
    }
    private func reflect(_ observation: KnowledgeObservationContent) {
        guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }
        reflectionRequestGeneration &+= 1
        let requestGeneration = reflectionRequestGeneration
        let requestIdentity = origin
        Task { @MainActor in
            guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity,
                  activity.allowsPresentationPublication else { return }
            do {
                let result = try await model.knowledge.reflect(sessionID: observation.range.sessionId, sourceRevisionIDs: [record.revisionId])
                guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity,
                      activity.allowsPresentationPublication else { return }
                if case .note = result.record.content { reflectedHandoff = result.record; message = "Reflected handoff generated; verify it before acting." } else { message = "Reflected handoff updated." }
            } catch is CancellationError { return }
            catch { guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = error.localizedDescription }
        }
    }
    private func triage() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; do { let result = try await model.knowledge.triage(sourceID: record.id, expectedRevision: record.revisionId); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = "Assessment updated (\(result.assessment.freshness.rawValue))." } catch is CancellationError { return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = error.localizedDescription } } }
    private func saveNote(_ note: KnowledgeNoteContent) { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; do { _ = try await model.knowledge.updateNote(id: record.id, expectedRevision: record.revisionId, record: KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: .note, scope: record.scope, provenance: record.provenance, temporal: record.temporal, relations: record.relations, importOrigin: record.importOrigin, content: .note(KnowledgeNoteContent(title: note.title, body: noteBody, fields: note.fields, role: note.role, confirmed: note.confirmed, contraryEvidence: note.contraryEvidence, freshness: note.freshness, privacyScope: note.privacyScope, usageConstraint: note.usageConstraint))), confirmedByUser: note.confirmed); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = "Saved"; await onChanged() } catch is CancellationError { return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = error.localizedDescription } } }
    private func exclude() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; do { _ = try await model.knowledge.setExclusion(recordID: record.id, expectedRevision: record.revisionId, excluded: true); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; dismiss() } catch is CancellationError { return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = error.localizedDescription } } }
    private func forget() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; do { _ = try await model.knowledge.forget(id: record.id, expectedRevision: record.revisionId, reason: "Forgotten from iOS"); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; dismiss() } catch is CancellationError { return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; message = error.localizedDescription } } }
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
    private var canSave: Bool { config != nil }
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) } }
            .task { await load() }
        }
    }
    private func load() async {
        let requestIdentity = model.knowledgePresentationIdentity
        do {
            let loaded = try await model.knowledge.status()
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity, requestIdentity.profileID != nil else { return }
            identity = requestIdentity; config = loaded.config; interestsText = loaded.config.currentInterests.joined(separator: "\n"); selectedSessionIDs = Set(loaded.config.eligibility.sessionIds); selectedProjectIDs = Set(loaded.config.eligibility.projectIds)
            if let value = loaded.config.observation.model { let parts = value.split(separator: "/", maxSplits: 1).map(String.init); if parts.count == 2 { chosenModel = ModelRef(provider: parts[0], id: parts[1]) } }
        } catch {
            guard activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            self.error = error.localizedDescription
        }
    }
    private func save() {
        guard var config else { return }
        guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { error = "Gateway changed; reopen configuration."; return }
        if config.observation.enabled && (chosenModel == nil || !hasScope) { error = "Select a model and at least one scope before enabling observation."; return }
        if let chosenModel { config.observation.model = chosenModel.contextWindowKey }
        config.eligibility.sessionIds = selectedSessionIDs.sorted(); config.eligibility.projectIds = selectedProjectIDs.sorted(); config.currentInterests = interestsText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50).map { String($0.prefix(500)) }
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        Task { @MainActor in
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            do { _ = try await model.knowledge.configure(config); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; dismiss() }
            catch is CancellationError { return }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; self.error = error.localizedDescription }
        }
    }
}

struct KnowledgeConnectorsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnowledgePresentationIdentity?
    @State private var statuses: [String: KnowledgeConnectorStatus] = [:]
    @State private var configuring: String?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List(["raindrop", "x"], id: \.self) { connector in
                VStack(alignment: .leading, spacing: 8) {
                    Label(connector == "x" ? "X" : "Raindrop", systemImage: "link").font(.headline)
                    Text(statuses[connector]?.detail ?? "Checking status…").font(.footnote).foregroundStyle(Color.tronTextSecondary)
                    if statuses[connector]?.writesEnabled == false { Text("Remote writes disabled").font(.caption).foregroundStyle(Color.tronAmber) }
                    HStack { Button("Refresh") { refresh(connector) }.buttonStyle(.bordered); Button("Configure") { configuring = connector }.buttonStyle(.bordered); Button("Run") { run(connector) }.buttonStyle(.borderedProminent).disabled(statuses[connector]?.configured != true) }
                }.padding(.vertical, 8)
            }
            .navigationTitle("Connectors")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { refresh("raindrop"); refresh("x") }
            .sheet(isPresented: Binding(get: { configuring != nil }, set: { if !$0 { configuring = nil } })) {
                if let connector = configuring { KnowledgeConnectorEditView(connector: connector, status: statuses[connector]) { configuring = nil; refresh(connector) }.environment(model) }
            }
            .alert("Connector", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
        }
    }
    private func refresh(_ connector: String) { guard activity.allowsPresentationPublication else { return }; let requestIdentity = model.knowledgePresentationIdentity; Task { @MainActor in guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; do { let status = try await model.knowledge.connectorStatus(connector); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; identity = requestIdentity; statuses[connector] = status } catch is CancellationError { return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; statuses[connector] = nil; message = error.localizedDescription } } }
    private func run(_ connector: String) { guard let status = statuses[connector], status.configured, activity.allowsPresentationPublication else { return }; let requestIdentity = identity ?? model.knowledgePresentationIdentity; Task { @MainActor in guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.runConnector(connector, dryRun: false); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = result.error ?? "Run accepted (\(result.pending) pending)." } catch is CancellationError { return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription } } }
}

private struct KnowledgeConnectorEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let connector: String
    let status: KnowledgeConnectorStatus?
    let onSaved: () -> Void
    @State private var enabled: Bool
    @State private var accountID: String
    @State private var scope: String
    @State private var destination = ""
    @State private var credentialRef = ""
    @State private var allowWrites: Bool
    @State private var paidAccessApproved: Bool
    @State private var recurringApproved: Bool
    @State private var error: String?
    init(connector: String, status: KnowledgeConnectorStatus?, onSaved: @escaping () -> Void) {
        self.connector = connector; self.status = status; self.onSaved = onSaved
        _enabled = State(initialValue: status?.enabled ?? false); _accountID = State(initialValue: status?.accountId ?? ""); _scope = State(initialValue: status?.scope ?? ""); _allowWrites = State(initialValue: status?.allowWrites ?? false); _paidAccessApproved = State(initialValue: status?.paidAccessApproved ?? false); _recurringApproved = State(initialValue: status?.recurringApproved ?? false)
    }
    var body: some View {
        NavigationStack { Form {
            Section("Account") { Toggle("Enabled", isOn: $enabled); TextField("Account ID", text: $accountID); TextField(connector == "raindrop" ? "Collection ID" : "User ID", text: $scope); SecureField("Mac Keychain reference", text: $credentialRef); Text("Credentials stay in the Mac Keychain; this is only an opaque reference.").font(.footnote).foregroundStyle(Color.tronTextSecondary) }
            if connector == "raindrop" { Section("Remote policy") { TextField("Destination collection (optional)", text: $destination); Toggle("Allow reversible moves", isOn: $allowWrites); Text("Moves require a complete local capture and verified remote state.").font(.footnote).foregroundStyle(Color.tronTextSecondary) } }
            Section("Access") { Toggle("Paid access approved", isOn: $paidAccessApproved); Toggle("Recurring runs approved", isOn: $recurringApproved) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(connector == "x" ? "X connector" : "Raindrop connector").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } } } }
    }
    private func save() {
        let requestIdentity = model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                _ = try await model.knowledge.configureConnector(connector, enabled: enabled, accountID: accountID.nilIfEmpty, scope: scope.nilIfEmpty, destination: destination.nilIfEmpty, credentialRef: credentialRef.nilIfEmpty, allowWrites: allowWrites, paidAccessApproved: paidAccessApproved, recurringApproved: recurringApproved)
                guard activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                onSaved(); dismiss()
            } catch let caught {
                guard activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                error = caught.localizedDescription
            }
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct KnowledgeImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var source = "personal-os"
    @State private var plan: KnowledgeImportPlan?
    @State private var message: String?
    @State private var confirmExecute = false
    @State private var identity: KnowledgePresentationIdentity?
    @State private var offset = 0
    @State private var planOffset: Int?
    @State private var planSource: String?
    @State private var canInspectNextBatch = false
    @State private var requestGeneration = 0
    var body: some View {
        NavigationStack {
            Form {
                Section("Read-only dry run") { Picker("Named source", selection: $source) { Text("Personal OS").tag("personal-os"); Text("LLM Wiki").tag("llm-wiki") }; Text("Only a deliberately configured named root on this Gateway can be read.").font(.footnote).foregroundStyle(Color.tronTextSecondary); Button("Inspect import") { offset = 0; dryRun(offset: 0) } }
                if let plan, planOffset == offset, planSource == source { Section("Inspected batch starting at \(offset)") { LabeledContent("Corpus progress", value: KnowledgeImportPresentationPolicy.corpusProgress(planned: plan.planned, selected: plan.selected, offset: offset)); LabeledContent("Warnings", value: "\(plan.warnings.count)"); LabeledContent("Skipped/withheld", value: "\(plan.skipped)"); Text("Plan hash: \(plan.planHash)").font(.caption).textSelection(.enabled); Button("Import accepted items") { confirmExecute = true }; if canInspectNextBatch && offset + plan.selected < plan.planned && plan.selected > 0 { Button("Inspect next batch") { dryRun(offset: offset + plan.selected) } } } }
                if let message { Text(message).foregroundStyle(Color.tronTextSecondary) }
            }.navigationTitle("Import Knowledge").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Execute this exact inspected import?", isPresented: $confirmExecute) { Button("Import", role: .destructive) { if let plan { execute(plan) } }; Button("Cancel", role: .cancel) {} }
        }
    }
    private func dryRun(offset requestedOffset: Int) {
        guard activity.allowsPresentationPublication else { return }
        requestGeneration &+= 1
        let request = requestGeneration
        let source = source
        let requestIdentity = model.knowledgePresentationIdentity
        offset = max(0, requestedOffset)
        plan = nil; planOffset = nil; planSource = nil; canInspectNextBatch = false; confirmExecute = false
        Task { @MainActor in
            guard request == requestGeneration, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let value = try await model.knowledge.importDryRun(source: source, offset: requestedOffset)
                guard request == requestGeneration, activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                identity = requestIdentity; plan = value; planOffset = requestedOffset; planSource = source; message = nil
            } catch is CancellationError { return }
            catch { guard request == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription }
        }
    }
    private func execute(_ plan: KnowledgeImportPlan) {
        guard let plannedOffset = planOffset, planSource == source, plannedOffset == offset,
              activity.allowsPresentationPublication,
              model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { message = "Gateway changed or this inspection is stale; inspect the source again."; return }
        requestGeneration &+= 1
        let request = requestGeneration
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        let plannedSource = planSource ?? source
        Task { @MainActor in
            guard request == requestGeneration, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let value = try await model.knowledge.importRun(source: plannedSource, planHash: plan.planHash, limit: plan.selected, offset: plannedOffset)
                guard request == requestGeneration, activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                canInspectNextBatch = value.failed == 0 && value.imported + value.resumed + value.skipped == plan.selected
                message = KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: value, offset: plannedOffset)
            } catch is CancellationError { return }
            catch { guard request == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription }
        }
    }
}

private struct KnowledgeCorrectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onComplete: () async -> Void
    @State private var text: String
    @State private var error: String?

    init(record: KnowledgeRecord, origin: KnowledgePresentationIdentity, onComplete: @escaping () async -> Void) {
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
        guard model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { error = "Gateway changed; reopen this entry."; return }
        let replacement = KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: record.kind, scope: record.scope, provenance: KnowledgeCorrectionPolicy.provenance(for: record), temporal: record.temporal, relations: record.relations, importOrigin: record.importOrigin, content: KnowledgeCorrectionPolicy.content(for: record, replacementText: text))
        let relation = KnowledgeRelation(type: .corrects, recordId: record.id, revisionId: record.revisionId, field: nil)
        Task { @MainActor in
            guard model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { return }
            do { _ = try await model.knowledge.correct(id: record.id, expectedRevision: record.revisionId, replacement: replacement, relation: relation, confirmedByUser: true); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; await onComplete() }
            catch is CancellationError { return }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; self.error = error.localizedDescription }
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
    private func capture() { guard valid else { error = "Use an http(s) URL without credentials."; return }; let identity = model.knowledgePresentationIdentity; let sourceURL = uri; let sourceTitle = title
        Task { @MainActor in guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; do { _ = try await model.knowledge.captureURL(url: sourceURL, title: sourceTitle, scope: scope); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; await onComplete(); dismiss() } catch is CancellationError { return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription } }
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
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack { Form {
            Section("Note") { TextField("Title", text: $title); TextEditor(text: $noteText).frame(minHeight: 140); Picker("Role", selection: $role) { ForEach(KnowledgeNoteRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }; Picker("Scope", selection: $scope) { ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.label).tag($0) } }; Toggle("Confirmed by me", isOn: $confirmed) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("New Note").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        let identity = model.knowledgePresentationIdentity; let record = KnowledgeRecordDraft(id: nil, createdAt: nil, updatedAt: nil, kind: .note, scope: scope, provenance: KnowledgeProvenance(actor: .user, source: "ios-note", sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [], content: .note(KnowledgeNoteContent(title: title, body: noteText.isEmpty ? nil : noteText, fields: nil, role: role, confirmed: confirmed, contraryEvidence: nil, freshness: .current, privacyScope: "private", usageConstraint: nil)))
        Task { @MainActor in guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; do { _ = try await model.knowledge.createNote(record, confirmedByUser: confirmed); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; await onComplete(); dismiss() } catch is CancellationError { saving = false; return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; saving = false; self.error = error.localizedDescription } }
    }
}
