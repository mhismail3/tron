import Testing
@testable import TronMobile

@Suite("Custom-model guided draft transformation")
struct CustomModelDraftTransformationTests {
    @Test("guided loading rejects roots and providers it cannot preserve")
    func rejectsLossyShapes() {
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.prepare(.array([]))
        }
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.prepare(.object(["providers": .array([])]))
        }
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.prepare(.object([
                "providers": .object(["custom": .string("not-an-object")]),
            ]))
        }
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.prepare(.object([
                "providers": .object([
                    "custom": .object([
                        "models": .array([
                            .object(["id": .string("same")]),
                            .object(["id": .string("same")]),
                        ]),
                    ]),
                ]),
            ]))
        }
    }

    @Test("normalized provider and model identities cannot collide")
    func rejectsGuidedCollisions() {
        let providers = [
            CustomModelProviderDraft(identifier: "custom"),
            CustomModelProviderDraft(identifier: " custom "),
        ]
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.rebuild(
                root: ["providers": .object([:])],
                providers: providers
            )
        }
        #expect(throws: CustomModelDraftTransformationError.self) {
            _ = try CustomModelDraftTransformation.rebuild(
                root: ["providers": .object([:])],
                providers: [CustomModelProviderDraft(
                    identifier: "custom",
                    models: "model-a\n model-a "
                )]
            )
        }
    }

    @Test("unknown and redacted fields survive guided edits")
    func preservesUnknownFields() throws {
        let source: JSONValue = .object([
            "topLevel": .object(["future": .bool(true)]),
            "providers": .object([
                "custom": .object([
                    "baseUrl": .string("https://old.invalid"),
                    "api": .string("openai-completions"),
                    "apiKey": .string("<redacted>"),
                    "futureProviderField": .number(7),
                    "models": .array([
                        .object([
                            "id": .string("model-a"),
                            "name": .string("Model A"),
                            "futureModelField": .string("preserved"),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let prepared = try CustomModelDraftTransformation.prepare(source)
        var provider = try #require(prepared.providers.first)
        provider.baseURL = "https://new.invalid"
        provider.models = "model-a\nmodel-b"
        let rendered = try CustomModelDraftTransformation.rebuild(
            root: prepared.root,
            providers: [provider]
        )
        let root = try #require(rendered.value.objectValue)
        #expect(root["topLevel"] == .object(["future": .bool(true)]))
        let custom = try #require(root["providers"]?.objectValue?["custom"]?.objectValue)
        #expect(custom["apiKey"] == .string("<redacted>"))
        #expect(custom["futureProviderField"] == .number(7))
        #expect(custom["baseUrl"] == .string("https://new.invalid"))
        let models = try #require(custom["models"]?.arrayValue)
        #expect(models[0].objectValue?["futureModelField"] == .string("preserved"))
        #expect(models[1].objectValue?["id"] == .string("model-b"))
    }

    @Test("large valid provider and model sets remain deterministic")
    func handlesLargeBoundedDrafts() throws {
        let providers = Dictionary(uniqueKeysWithValues: (0..<100).map { providerIndex in
            let models = (0..<100).map { modelIndex in
                JSONValue.object(["id": .string("model-\(providerIndex)-\(modelIndex)")])
            }
            return ("provider-\(providerIndex)", JSONValue.object(["models": .array(models)]))
        })
        let source = JSONValue.object(["providers": .object(providers)])
        let prepared = try CustomModelDraftTransformation.prepare(source)
        let rendered = try CustomModelDraftTransformation.rebuild(
            root: prepared.root,
            providers: prepared.providers
        )
        #expect(prepared.providers.count == 100)
        #expect(rendered.value == source)
        #expect(rendered.document == source.prettyPrinted)
    }
}
