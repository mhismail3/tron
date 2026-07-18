import Foundation
import Testing
@testable import TronMobile

@Suite("Native UI runtime")
struct NativeUIRuntimeTests {
    @Test("Bundled proof definitions decode and build validated trees")
    func bundledDefinitionsValidate() throws {
        for definitionId in ["settings.engine", "session.compaction_detail", "lab.catalog"] {
            let definition = try NativeUIBundledDefinitions.load(definitionId)
            #expect(definition.schemaVersion == NativeUICatalog.schemaVersion)
            #expect(definition.catalogId == NativeUICatalog.id)
            #expect(definition.catalogRevision == NativeUICatalog.revision)
            let bytes = try JSONEncoder().encode(definition).count
            let tree = try NativeUIValidator.buildValidatedTree(
                messages: definition.messages,
                encodedByteCount: bytes
            )
            #expect(tree.root?.component == "Surface")
        }
    }

    @Test("Surface Lab covers every catalog component and ordered modifier")
    func labCoversCatalog() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        let components = definition.messages
            .compactMap(\.updateComponents)
            .flatMap(\.components)
        #expect(Set(components.map(\.component)) == NativeUICatalog.components)

        let modifierNames = components.flatMap { component -> [String] in
            component.properties["modifiers"]?.arrayValue?.compactMap {
                $0.objectValue?["name"]?.stringValue
            } ?? []
        }
        #expect(Set(modifierNames) == NativeUICatalog.modifiers)

        let ordered = components.first(where: { $0.id == "modifier-text" })?
            .properties["modifiers"]?.arrayValue?.compactMap {
                $0.objectValue?["name"]?.stringValue
            }
        #expect(ordered?.prefix(3) == ["frame", "padding", "offset"])
    }

    @Test("Duplicate IDs and cycles fail closed")
    func invalidGraphsFailClosed() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        let update = try #require(definition.messages.compactMap(\.updateComponents).first)

        var duplicateComponents = update.components
        duplicateComponents[1] = NativeUIComponentDTO(
            id: duplicateComponents[0].id,
            component: duplicateComponents[1].component,
            properties: duplicateComponents[1].properties
        )
        let duplicate = replacingComponents(definition.messages, with: duplicateComponents)
        #expect(throws: NativeUIRuntimeError.self) {
            try NativeUIValidator.buildValidatedTree(messages: duplicate)
        }

        var cycleComponents = update.components
        let rootIndex = try #require(cycleComponents.firstIndex(where: { $0.id == "root" }))
        cycleComponents[rootIndex] = NativeUIComponentDTO(
            id: "root",
            component: "Surface",
            properties: ["child": .string("root")]
        )
        let cycle = replacingComponents(definition.messages, with: cycleComponents)
        #expect(throws: NativeUIRuntimeError.self) {
            try NativeUIValidator.buildValidatedTree(messages: cycle)
        }

        var malformedComponents = update.components
        let sliderIndex = try #require(malformedComponents.firstIndex(where: { $0.id == "lab-slider" }))
        var sliderProperties = malformedComponents[sliderIndex].properties
        sliderProperties["step"] = .string("fast")
        malformedComponents[sliderIndex] = NativeUIComponentDTO(
            id: "lab-slider",
            component: "Slider",
            properties: sliderProperties
        )
        #expect(throws: NativeUIRuntimeError.self) {
            try NativeUIValidator.buildValidatedTree(
                messages: replacingComponents(definition.messages, with: malformedComponents)
            )
        }

        var colorComponents = update.components
        let textIndex = try #require(colorComponents.firstIndex(where: { $0.id == "lab-text" }))
        var textProperties = colorComponents[textIndex].properties
        textProperties["modifiers"] = .array([
            .object(["name": .string("foregroundStyle"), "value": .string("unregistered-color")]),
        ])
        colorComponents[textIndex] = NativeUIComponentDTO(
            id: "lab-text", component: "Text", properties: textProperties
        )
        #expect(throws: NativeUIRuntimeError.self) {
            try NativeUIValidator.buildValidatedTree(
                messages: replacingComponents(definition.messages, with: colorComponents)
            )
        }
    }

    @Test("A rejected multi-record batch never changes the visible tree")
    func rejectedBatchIsAtomic() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        let snapshot = snapshot(definition)
        var assembler = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        let initial = try assembler.install(snapshot: snapshot)

        let firstMessage = dataMessage(path: "/toggle", value: .bool(false))
        let first = record(message: firstMessage, index: 0, count: 2, final: false)
        #expect(assembler.ingest(first, cursor: .init(rawValue: 10)) == .staged)
        #expect(assembler.visibleTree == initial)

        let malformed = NativeUIMessageDTO(
            version: "v999",
            createSurface: nil,
            updateComponents: nil,
            updateDataModel: NativeUIUpdateDataModelDTO(
                surfaceId: "lab.catalog",
                path: "/toggle",
                value: .bool(true)
            ),
            deleteSurface: nil
        )
        let second = record(message: malformed, index: 1, count: 2, final: true)
        #expect(assembler.ingest(second, cursor: .init(rawValue: 11)) == .reconstructionRequired("invalid_batch_message"))
        #expect(assembler.visibleTree == initial)
    }

    @Test("Cursor gaps, duplicate records, and missing commits request recovery")
    func streamContinuityFailsClosed() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        var assembler = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        _ = try assembler.install(snapshot: snapshot(definition))

        let update = record(
            message: dataMessage(path: "/toggle", value: .bool(false)),
            index: 0,
            count: 1,
            final: true,
            batchId: "complete"
        )
        if case .committed(let tree) = assembler.ingest(update, cursor: .init(rawValue: 30)) {
            #expect(tree.value(at: "/toggle") == .bool(false))
        } else {
            Issue.record("Expected committed update")
        }
        #expect(assembler.ingest(update, cursor: .init(rawValue: 30)) == .ignored)

        let duplicateSequence = record(
            message: dataMessage(path: "/toggle", value: .bool(true)),
            index: 0,
            count: 1,
            final: true,
            batchId: "duplicate-sequence",
            sequence: 1
        )
        #expect(assembler.ingest(
            duplicateSequence,
            cursor: .init(rawValue: 31)
        ) == .reconstructionRequired("surface_sequence_gap"))

        assembler.resetStreamState()

        let gap = record(
            message: dataMessage(path: "/toggle", value: .bool(true)),
            index: 0,
            count: 1,
            final: true,
            batchId: "gap"
        )
        _ = assembler.ingest(gap, cursor: .init(rawValue: 30))
        #expect(assembler.ingest(gap, cursor: .init(rawValue: 32)) == .reconstructionRequired("cursor_gap"))

        let pending = record(
            message: dataMessage(path: "/toggle", value: .bool(true)),
            index: 0,
            count: 2,
            final: false,
            batchId: "missing-commit",
            sequence: 2
        )
        #expect(assembler.ingest(pending, cursor: .init(rawValue: 33)) == .staged)
        let expired = assembler.expirePendingBatches(olderThan: .zero)
        #expect(expired)
    }

    @Test("Insertion, update, visible removal, reorder, reconnect, and delete use one atomic runtime")
    func incrementalGraphChangesAndReconstruction() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        let original = snapshot(definition)
        var assembler = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        let initial = try assembler.install(snapshot: original)

        let inserted = NativeUIMessageDTO(
            version: NativeUICatalog.a2uiVersion,
            createSurface: nil,
            updateComponents: NativeUIUpdateComponentsDTO(
                surfaceId: "lab.catalog",
                components: [NativeUIComponentDTO(
                    id: "stream-inserted",
                    component: "Text",
                    properties: ["text": .string("Inserted")]
                )]
            ),
            updateDataModel: nil,
            deleteSurface: nil
        )
        let updated = NativeUIMessageDTO(
            version: NativeUICatalog.a2uiVersion,
            createSurface: nil,
            updateComponents: NativeUIUpdateComponentsDTO(
                surfaceId: "lab.catalog",
                components: [NativeUIComponentDTO(
                    id: "lab-row-a",
                    component: "Text",
                    properties: ["text": .string("Updated")]
                )]
            ),
            updateDataModel: nil,
            deleteSurface: nil
        )
        let reordered = NativeUIMessageDTO(
            version: NativeUICatalog.a2uiVersion,
            createSurface: nil,
            updateComponents: NativeUIUpdateComponentsDTO(
                surfaceId: "lab.catalog",
                components: [NativeUIComponentDTO(
                    id: "lab-row",
                    component: "Row",
                    properties: [
                        "children": .array([
                            .string("stream-inserted"),
                            .string("lab-row-a"),
                            .string("lab-divider"),
                        ]),
                    ]
                )]
            ),
            updateDataModel: nil,
            deleteSurface: nil
        )
        let messages = [inserted, updated, reordered]
        for index in messages.indices {
            let result = assembler.ingest(
                record(
                    message: messages[index],
                    index: index,
                    count: messages.count,
                    final: index == messages.count - 1,
                    batchId: "graph-change"
                ),
                cursor: .init(rawValue: UInt64(100 + index))
            )
            if index < messages.count - 1 {
                #expect(result == .staged)
                #expect(assembler.visibleTree == initial)
            } else if case .committed(let tree) = result {
                #expect(tree.components["stream-inserted"]?.properties["text"] == .string("Inserted"))
                #expect(tree.components["lab-row-a"]?.properties["text"] == .string("Updated"))
                #expect(tree.components["lab-row"]?.properties["children"] == .array([
                    .string("stream-inserted"), .string("lab-row-a"), .string("lab-divider"),
                ]))
                let compacted = try tree.canonicalMessages()
                #expect(compacted.count == 3)
                #expect(try NativeUIValidator.buildValidatedTree(messages: compacted) == tree)
            } else {
                Issue.record("Expected the complete graph batch to commit")
            }
        }

        let reconstructed = NativeUISurfaceSnapshotDTO(
            surfaceId: original.surfaceId,
            definitionId: original.definitionId,
            definitionRevision: original.definitionRevision,
            surfaceSequence: 0,
            catalogId: original.catalogId,
            catalogRevision: original.catalogRevision,
            lifecycle: original.lifecycle,
            source: "reconstructed",
            presentation: original.presentation,
            messages: original.messages + [dataMessage(path: "/toggle", value: .bool(false))],
            diagnostics: [],
            sessionId: nil,
            eventId: nil
        )
        assembler.resetStreamState()
        let restored = try assembler.install(snapshot: reconstructed)
        #expect(restored.value(at: "/toggle") == .bool(false))

        let deletion = NativeUIMessageDTO(
            version: NativeUICatalog.a2uiVersion,
            createSurface: nil,
            updateComponents: nil,
            updateDataModel: nil,
            deleteSurface: NativeUIDeleteSurfaceDTO(surfaceId: "lab.catalog")
        )
        #expect(assembler.ingest(
            record(message: deletion, index: 0, count: 1, final: true, batchId: "delete"),
            cursor: .init(rawValue: 200)
        ) == .deleted)
        #expect(assembler.visibleTree == nil)
    }

    @Test("Stream envelopes, ordering, and batch bounds fail closed")
    func streamEnvelopeAndBoundsFailClosed() throws {
        let definition = try NativeUIBundledDefinitions.load("lab.catalog")
        let update = dataMessage(path: "/toggle", value: .bool(false))

        var barrier = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        _ = try barrier.install(snapshot: snapshot(definition, surfaceSequence: 5))
        #expect(barrier.ingest(
            record(
                message: update,
                index: 0,
                count: 1,
                final: true,
                sequence: 5,
                catalogRevision: NativeUICatalog.revision + 1
            ),
            cursor: .init(rawValue: 1)
        ) == .ignored)
        if case .committed(let tree) = barrier.ingest(
            record(message: update, index: 0, count: 1, final: true, sequence: 6),
            cursor: .init(rawValue: 2)
        ) {
            #expect(tree.value(at: "/toggle") == .bool(false))
        } else {
            Issue.record("Expected the first update after the snapshot barrier to commit")
        }

        var incompatible = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        _ = try incompatible.install(snapshot: snapshot(definition))
        #expect(incompatible.ingest(
            record(
                message: update,
                index: 0,
                count: 1,
                final: true,
                catalogRevision: NativeUICatalog.revision + 1
            ),
            cursor: .init(rawValue: 1)
        ) == .reconstructionRequired("incompatible_stream_envelope"))

        var outOfOrder = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        _ = try outOfOrder.install(snapshot: snapshot(definition))
        #expect(outOfOrder.ingest(
            record(message: update, index: 1, count: 2, final: true, sequence: 1),
            cursor: .init(rawValue: 1)
        ) == .reconstructionRequired("batch_capacity_or_order"))

        var oversized = NativeUIBatchAssembler(surfaceId: "lab.catalog")
        _ = try oversized.install(snapshot: snapshot(definition))
        #expect(oversized.ingest(
            record(
                message: update,
                index: 0,
                count: NativeUICatalog.maxMessagesPerBatch + 1,
                final: false
            ),
            cursor: .init(rawValue: 1)
        ) == .reconstructionRequired("invalid_batch_envelope"))
        #expect(oversized.visibleTree != nil)
    }

    @Test("Client function advertisement is revision pinned and schema complete")
    @MainActor
    func clientCatalogIsComplete() throws {
        let catalog = NativeUIClientBridge.catalog(clientId: "test-client")
        #expect(catalog.catalogId == NativeUICatalog.id)
        #expect(catalog.catalogRevision == NativeUICatalog.revision)
        #expect(Set(catalog.functions.map {
            NativeUIClientFunctionIdentity(name: $0.name, revision: $0.revision)
        }) == NativeUICatalog.clientFunctions)
        for function in catalog.functions {
            #expect(function.parameters.objectValue?["type"] == .string("object"))
            #expect(function.parameters.objectValue?["additionalProperties"] == .bool(false))
        }
        #expect(try JSONEncoder().encode(catalog).count < NativeUICatalog.maxPayloadBytes)
    }

    @Test("Transient restoration is session scoped and a local dismissal tombstone wins")
    @MainActor
    func transientRestorationHonorsDismissal() throws {
        try IsolatedTestState.withDefaults(label: "native-ui-transient") { defaults in
            let definition = try NativeUIBundledDefinitions.load("session.compaction_detail")
            let transient = NativeUISurfaceSnapshotDTO(
                surfaceId: "session.compaction_detail:session-a:event-a",
                definitionId: definition.definitionId,
                definitionRevision: 1,
                surfaceSequence: 0,
                catalogId: definition.catalogId,
                catalogRevision: definition.catalogRevision,
                lifecycle: "transient",
                source: "test",
                presentation: definition.presentation,
                messages: definition.messages,
                diagnostics: [],
                sessionId: "session-a",
                eventId: "event-a"
            )
            let cache = NativeUISnapshotCache(namespace: "server-a", defaults: defaults)

            cache.save(transient)
            #expect(cache.latestActiveTransient(
                sessionId: "session-a",
                definitionId: "session.compaction_detail"
            )?.eventId == "event-a")
            #expect(cache.latestActiveTransient(
                sessionId: "session-b",
                definitionId: "session.compaction_detail"
            ) == nil)

            cache.remove(surfaceId: transient.surfaceId)
            #expect(cache.isDismissed(surfaceId: transient.surfaceId))
            #expect(cache.latestActiveTransient(
                sessionId: "session-a",
                definitionId: "session.compaction_detail"
            ) == nil)
        }
    }

    private func replacingComponents(
        _ messages: [NativeUIMessageDTO],
        with components: [NativeUIComponentDTO]
    ) -> [NativeUIMessageDTO] {
        messages.map { message in
            guard let update = message.updateComponents else { return message }
            return NativeUIMessageDTO(
                version: message.version,
                createSurface: nil,
                updateComponents: NativeUIUpdateComponentsDTO(
                    surfaceId: update.surfaceId,
                    components: components
                ),
                updateDataModel: nil,
                deleteSurface: nil
            )
        }
    }

    private func snapshot(
        _ definition: NativeUIDefinitionDTO,
        surfaceSequence: UInt64 = 0
    ) -> NativeUISurfaceSnapshotDTO {
        NativeUISurfaceSnapshotDTO(
            surfaceId: definition.definitionId,
            definitionId: definition.definitionId,
            definitionRevision: 0,
            surfaceSequence: surfaceSequence,
            catalogId: definition.catalogId,
            catalogRevision: definition.catalogRevision,
            lifecycle: definition.lifecycle,
            source: "test",
            presentation: definition.presentation,
            messages: definition.messages,
            diagnostics: [],
            sessionId: nil,
            eventId: nil
        )
    }

    private func dataMessage(path: String, value: NativeUIJSONValue) -> NativeUIMessageDTO {
        NativeUIMessageDTO(
            version: NativeUICatalog.a2uiVersion,
            createSurface: nil,
            updateComponents: nil,
            updateDataModel: NativeUIUpdateDataModelDTO(
                surfaceId: "lab.catalog",
                path: path,
                value: value
            ),
            deleteSurface: nil
        )
    }

    private func record(
        message: NativeUIMessageDTO,
        index: Int,
        count: Int,
        final: Bool,
        batchId: String = "batch",
        sequence: UInt64? = nil,
        catalogRevision: UInt64 = NativeUICatalog.revision
    ) -> NativeUISurfaceStreamRecordDTO {
        NativeUISurfaceStreamRecordDTO(
            surfaceId: "lab.catalog",
            definitionId: "lab.catalog",
            definitionRevision: 1,
            catalogId: NativeUICatalog.id,
            catalogRevision: catalogRevision,
            lifecycle: "persistent",
            sequence: sequence ?? UInt64(index + 1),
            batchId: batchId,
            batchIndex: index,
            batchCount: count,
            isFinal: final,
            message: message
        )
    }
}
