import SwiftUI

/// Developer proof surface. Definition lifecycle controls call the same
/// validate/preview/activate/history/rollback capabilities used by future agent
/// publication; the fixture itself uses the production runtime below.
struct SurfaceLabView: View {
    let repository: any NativeUIRepository
    let cacheNamespace: String

    @State private var definitionText = ""
    @State private var validation: NativeUIValidationReportDTO?
    @State private var revisions: [NativeUIDefinitionRevisionDTO] = []
    @State private var operationMessage: String?
    @State private var streamProofMessage: String?
    @State private var isWorking = false
    @State private var fixture: Fixture = .valid

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            lifecycleControls

            NativeUISurfaceView(
                repository: repository,
                request: NativeUISurfaceRequest(
                    definitionId: "lab.catalog",
                    surfaceId: "lab.catalog"
                ),
                cacheNamespace: cacheNamespace
            )
            .id(revisions.first(where: { $0.status == "active" })?.revision ?? 0)
            .accessibilityIdentifier("native-ui.surface-lab")
        }
        .task {
            loadFixture(.valid)
            await refreshHistory()
        }
    }

    private var lifecycleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Definition lifecycle", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }

            Picker("Fixture", selection: $fixture) {
                ForEach(Fixture.allCases) { fixture in Text(fixture.title).tag(fixture) }
            }
            .pickerStyle(.menu)
            .onChange(of: fixture) { _, fixture in loadFixture(fixture) }

            TextEditor(text: $definitionText)
                .font(TronTypography.codeCaption)
                .frame(minHeight: 120, maxHeight: 180)
                .padding(8)
                .background(Color.tronSurface.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("surface-lab-definition-editor")

            HStack(spacing: 8) {
                actionButton("Validate", icon: "checkmark.shield", action: validate)
                actionButton("Preview", icon: "eye", action: preview)
                actionButton("Activate", icon: "bolt", action: activate)
                actionButton("History", icon: "clock.arrow.circlepath", action: refreshHistory)
            }

            Button {
                runStreamProof()
            } label: {
                Label("Run transactional stream proof", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            }
            .buttonStyle(.bordered)

            if let streamProofMessage {
                Label(streamProofMessage, systemImage: "checkmark.shield.fill")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronSuccess)
            }

            if let validation {
                Label(
                    validation.valid
                        ? "Valid • \(validation.contentHash.prefix(12))"
                        : "Rejected • \(validation.diagnostics.count) issue(s)",
                    systemImage: validation.valid ? "checkmark.circle.fill" : "xmark.octagon.fill"
                )
                .font(TronTypography.codeCaption)
                .foregroundStyle(validation.valid ? Color.tronSuccess : Color.tronError)
                ForEach(Array(validation.diagnostics.prefix(4).enumerated()), id: \.offset) { _, diagnostic in
                    Text("\(diagnostic.path): \(diagnostic.message)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            if let operationMessage {
                Text(operationMessage)
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextSecondary)
            }

            if !revisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revision history")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextMuted)
                    ForEach(revisions.prefix(5)) { revision in
                        HStack {
                            Text("r\(revision.revision)").font(TronTypography.codeCaption)
                            Text(revision.status)
                                .font(TronTypography.caption)
                                .foregroundStyle(.tronTextSecondary)
                            Spacer()
                            if revision.status != "active" {
                                Button("Rollback") { Task { await rollback(to: revision.revision) } }
                                    .font(TronTypography.caption)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }

    private func decodeDefinition() throws -> NativeUIDefinitionDTO {
        try JSONDecoder().decode(NativeUIDefinitionDTO.self, from: Data(definitionText.utf8))
    }

    private func validate() async {
        await runOperation {
            let response = try await repository.validate(decodeDefinition())
            validation = response.report
            operationMessage = response.report.valid
                ? "Validation passed without activation."
                : "Validation rejected."
        }
    }

    private func preview() async {
        await runOperation {
            let response = try await repository.preview(decodeDefinition())
            operationMessage = "Preview r\(response.revision.revision) created; active UI unchanged."
            await refreshHistory()
        }
    }

    private func activate() async {
        await runOperation {
            let expected = revisions.first(where: { $0.status == "active" })?.revision
            let response = try await repository.activate(
                decodeDefinition(),
                expectedActiveRevision: expected
            )
            operationMessage = "Activated r\(response.revision.revision) through compare-and-swap."
            await refreshHistory()
        }
    }

    private func refreshHistory() async {
        do {
            revisions = try await repository.history(definitionId: "lab.catalog")
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    private func rollback(to revision: UInt64) async {
        await runOperation {
            let expected = revisions.first(where: { $0.status == "active" })?.revision
            let response = try await repository.rollback(
                definitionId: "lab.catalog",
                targetRevision: revision,
                expectedActiveRevision: expected
            )
            operationMessage = "Rolled back to r\(response.revision.revision)."
            await refreshHistory()
        }
    }

    private func runOperation(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await operation() }
        catch {
            validation = nil
            operationMessage = error.localizedDescription
        }
    }

    private func loadFixture(_ fixture: Fixture) {
        guard let definition = try? NativeUIBundledDefinitions.load("lab.catalog"),
              var object = try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode(definition)
              ) as? [String: Any]
        else { return }
        switch fixture {
        case .valid: break
        case .duplicateId:
            mutateComponents(&object) { components in
                if components.count > 1 { components[1]["id"] = components[0]["id"] }
            }
        case .cycle:
            mutateComponents(&object) { components in
                if let root = components.firstIndex(where: { $0["id"] as? String == "root" }) {
                    components[root]["child"] = "root"
                }
            }
        case .incompatibleCatalog:
            object["catalogRevision"] = 999
        case .invalidModifier:
            mutateComponents(&object) { components in
                guard let index = components.firstIndex(where: { $0["id"] as? String == "lab-text" })
                else { return }
                components[index]["modifiers"] = [["name": "unregisteredModifier"]]
            }
        case .staleClientFunction:
            mutateComponents(&object) { components in
                guard let index = components.firstIndex(where: { $0["id"] as? String == "lab-button" }),
                      var action = components[index]["action"] as? [String: Any],
                      var function = action["clientFunction"] as? [String: Any]
                else { return }
                function["revision"] = 999
                action["clientFunction"] = function
                components[index]["action"] = action
            }
        case .unboundCapability:
            mutateComponents(&object) { components in
                guard let index = components.firstIndex(where: { $0["id"] as? String == "lab-button" })
                else { return }
                components[index]["action"] = [
                    "serverCapability": [
                        "functionId": "native_ui::missing_lab_capability",
                        "argumentTemplate": [:],
                    ],
                ]
            }
        case .oversized:
            mutateComponents(&object) { components in
                components.append([
                    "id": "oversized-text",
                    "component": "Text",
                    "text": String(repeating: "x", count: NativeUICatalog.maxTextBytes + 1),
                ])
            }
        case .malformed:
            definitionText = "{\"schemaVersion\":"
            validation = nil
            return
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            definitionText = String(decoding: data, as: UTF8.self)
        }
        validation = nil
    }

    /// Runs the production candidate tree and batch assembler in-app. The
    /// server-backed lifecycle controls above remain the proof for publication;
    /// this local harness makes stream fault behavior directly inspectable.
    private func runStreamProof() {
        do {
            let definition = try NativeUIBundledDefinitions.load("lab.catalog")
            let snapshot = NativeUISurfaceSnapshotDTO(
                surfaceId: "lab.catalog",
                definitionId: definition.definitionId,
                definitionRevision: 0,
                surfaceSequence: 0,
                catalogId: definition.catalogId,
                catalogRevision: definition.catalogRevision,
                lifecycle: definition.lifecycle,
                source: "surfaceLab",
                presentation: definition.presentation,
                messages: definition.messages,
                diagnostics: [],
                sessionId: nil,
                eventId: nil
            )
            var assembler = NativeUIBatchAssembler(surfaceId: "lab.catalog")
            let before = try assembler.install(snapshot: snapshot)
            let insertion = NativeUIMessageDTO(
                version: NativeUICatalog.a2uiVersion,
                createSurface: nil,
                updateComponents: NativeUIUpdateComponentsDTO(
                    surfaceId: "lab.catalog",
                    components: [NativeUIComponentDTO(
                        id: "lab-stream-inserted",
                        component: "Text",
                        properties: ["text": .string("Atomic insert")]
                    )]
                ),
                updateDataModel: nil,
                deleteSurface: nil
            )
            let reorder = NativeUIMessageDTO(
                version: NativeUICatalog.a2uiVersion,
                createSurface: nil,
                updateComponents: NativeUIUpdateComponentsDTO(
                    surfaceId: "lab.catalog",
                    components: [NativeUIComponentDTO(
                        id: "lab-row",
                        component: "Row",
                        properties: ["children": .array([
                            .string("lab-stream-inserted"),
                            .string("lab-row-a"),
                            .string("lab-divider"),
                        ])]
                    )]
                ),
                updateDataModel: nil,
                deleteSurface: nil
            )
            guard assembler.ingest(
                labRecord(insertion, sequence: 1, index: 0, count: 2, final: false),
                cursor: .init(rawValue: 1)
            ) == .staged,
            assembler.visibleTree == before,
            case .committed = assembler.ingest(
                labRecord(reorder, sequence: 2, index: 1, count: 2, final: true),
                cursor: .init(rawValue: 2)
            ),
            assembler.ingest(
                labRecord(insertion, sequence: 3, index: 0, count: 1, final: true),
                cursor: .init(rawValue: 4)
            ) == .reconstructionRequired("cursor_gap")
            else {
                throw NativeUIRuntimeError.batchRejected("Surface Lab stream assertion failed")
            }
            assembler.resetStreamState()
            _ = try assembler.install(snapshot: snapshot)
            streamProofMessage = "Insert/update/removal/reorder, atomic commit, gap rejection, reconnect, and reconstruction passed."
        } catch {
            streamProofMessage = nil
            operationMessage = error.localizedDescription
        }
    }

    private func labRecord(
        _ message: NativeUIMessageDTO,
        sequence: UInt64,
        index: Int,
        count: Int,
        final: Bool
    ) -> NativeUISurfaceStreamRecordDTO {
        NativeUISurfaceStreamRecordDTO(
            surfaceId: "lab.catalog",
            definitionId: "lab.catalog",
            definitionRevision: 1,
            catalogId: NativeUICatalog.id,
            catalogRevision: NativeUICatalog.revision,
            lifecycle: "persistent",
            sequence: sequence,
            batchId: "surface-lab-proof",
            batchIndex: index,
            batchCount: count,
            isFinal: final,
            message: message
        )
    }

    private func mutateComponents(
        _ object: inout [String: Any],
        mutation: (inout [[String: Any]]) -> Void
    ) {
        guard var messages = object["messages"] as? [[String: Any]],
              let index = messages.firstIndex(where: { $0["updateComponents"] != nil }),
              var update = messages[index]["updateComponents"] as? [String: Any],
              var components = update["components"] as? [[String: Any]]
        else { return }
        mutation(&components)
        update["components"] = components
        messages[index]["updateComponents"] = update
        object["messages"] = messages
    }
}

private extension SurfaceLabView {
    enum Fixture: String, CaseIterable, Identifiable {
        case valid
        case malformed
        case oversized
        case cycle
        case duplicateId
        case incompatibleCatalog
        case invalidModifier
        case staleClientFunction
        case unboundCapability

        var id: String { rawValue }
        var title: String {
            switch self {
            case .valid: "Valid"
            case .malformed: "Malformed JSON"
            case .oversized: "Oversized"
            case .cycle: "Cyclic graph"
            case .duplicateId: "Duplicate ID"
            case .incompatibleCatalog: "Incompatible catalog"
            case .invalidModifier: "Invalid modifier"
            case .staleClientFunction: "Stale client schema"
            case .unboundCapability: "Unbound capability"
            }
        }
    }
}
