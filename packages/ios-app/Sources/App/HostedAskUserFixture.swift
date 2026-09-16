#if HOSTED_TEST
import Foundation
import PhotosUI
import SwiftUI

/// A deterministic, test-only host for the rendered Ask User route. It keeps
/// the real managed sheet and AppModel mutation owner in the loop while the
/// socket supplies only a bounded synthetic transport response.
@MainActor
struct HostedAskUserFixtureView: View {
    private let sessionID = "hosted-ask-user-session"
    private let fixture: HostedAskUserFixture
    @State private var model: AppModel
    @ObservedObject private var receipt: HostedAskUserFixtureReceipt
    @State private var interaction: ExtensionInteraction?
    @State private var completed: AskUserToolPresentation?
    @State private var showContext = false
    @State private var showSettings = false
    @State private var queuedMessageEditor: QueuedMessageEditorRoute?
    @State private var cameraPresented = false
    @State private var photosPresented = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var processesPresented = false
    @State private var filesPresented = false
    @State private var editorRequest: ComposerEditorRequest?
    @State private var displaySheet: DisplayRoute?
    @State private var presentationActivity = PresentationActivityCoordinator()
    @State private var bootstrapError: String?

    init() {
        let fixture = HostedAskUserFixture()
        self.fixture = fixture
        _model = State(initialValue: fixture.model)
        _receipt = ObservedObject(wrappedValue: fixture.receipt)
    }

    var body: some View {
        TronPresentationSurface(id: "hosted-ask-user-fixture") {
            NavigationStack {
                if let completed {
                    VStack(spacing: 0) {
                        Text(completed.form.title)
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Mutation count: \(receipt.count)")
                            .accessibilityIdentifier("ask-user-mutation-count")
                        Text(receipt.summary)
                            .accessibilityIdentifier("ask-user-receipt")
                        AskUserCompletedFormView(presentation: completed)
                    }
                    .accessibilityIdentifier("ask-user-completed-route")
                } else if let bootstrapError {
                    Text(bootstrapError)
                        .accessibilityIdentifier("ask-user-bootstrap-error")
                } else {
                    VStack(spacing: 16) {
                        Text("Ask User fixture")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        Text("Mutation count: \(receipt.count)")
                            .accessibilityIdentifier("ask-user-mutation-count")
                        Text(receipt.summary)
                            .accessibilityIdentifier("ask-user-receipt")
                        Button("Reopen Ask User") {
                            interaction = fixture.interaction
                        }
                        .accessibilityIdentifier("ask-user-reopen")
                        if interaction == nil {
                            Text("Form closed")
                        }
                    }
                }
            }
            .modifier(ChatRoutes(
                sessionID: sessionID,
                projectCWD: nil,
                initialHistoryEntryID: nil,
                onForkCreated: { _ in },
                showContext: $showContext,
                showSettings: $showSettings,
                queuedMessageEditor: $queuedMessageEditor,
                queueCommit: nil,
                mutatingQueuedMessageIDs: [],
                onUpdateQueuedMessage: { _, _, _, _ in },
                onRemoveQueuedMessage: { _, _ in },
                cameraPresented: $cameraPresented,
                photosPresented: $photosPresented,
                photos: $photos,
                onCameraImage: { _ in },
                processesPresented: $processesPresented,
                interaction: $interaction,
                onInteractionClosed: { value in
                    interaction = nil
                    if receipt.count > 0 {
                        completed = AskUserToolPresentation(
                            form: value.form ?? fixture.form,
                            answer: receipt.lastCancelled ? nil : fixture.answer,
                            cancelled: receipt.lastCancelled
                        )
                    }
                },
                filesPresented: $filesPresented,
                onFileImport: { _ in },
                editorRequest: $editorRequest,
                displaySheet: $displaySheet,
                onUseEditorRequest: { _ in },
                onKeepEditorRequest: { _ in }
            ))
        }
        .environment(model)
        .environment(\.tronPresentationActivityCoordinator, presentationActivity)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: fixture.profile, token: fixture.token)
                model.installHostedSubscribedSnapshot(fixture.snapshot)
                interaction = fixture.interaction
            } catch {
                bootstrapError = "Ask User fixture bootstrap failed: \(error.localizedDescription)"
            }
        }
    }
}

@MainActor
private final class HostedAskUserFixtureReceipt: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var summary = "No mutation"
    private(set) var lastCancelled = false

    func record(
        cancelled: Bool,
        value: JSONValue?,
        interactionID: String,
        hostEpoch: String,
        presentationRevision: Int
    ) {
        count += 1
        lastCancelled = cancelled
        let scope = "scope=\(interactionID)/\(hostEpoch)/\(presentationRevision)"
        if cancelled {
            summary = "extension.respond cancelled=true \(scope)"
        } else {
            let answer = value?.objectValue?["answers"]?.arrayValue?.first?.objectValue
            let selected = answer?["optionIds"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: ",") ?? ""
            let other = answer?["other"]?.stringValue ?? ""
            summary = "extension.respond cancelled=false selected=\(selected) other=\(other)"
        }
    }
}

private struct HostedAskUserFixture {
    let profile: GatewayProfile
    let token = "hosted-ask-user-token"
    let interaction: ExtensionInteraction
    let form: ExtensionFormDescriptor
    let answer: ExtensionFormAnswer
    let snapshot: SessionSnapshot
    let receipt: HostedAskUserFixtureReceipt
    let model: AppModel

    @MainActor
    init() {
        let receipt = HostedAskUserFixtureReceipt()
        self.receipt = receipt
        let allowCancel = !ProcessInfo.processInfo.arguments.contains("-tron-ask-user-no-cancel")
        let styled = ProcessInfo.processInfo.arguments.contains("-tron-ask-user-styled")
        let optionA = ExtensionFormOption(id: "environment-a", label: "Staging", description: styled ? "A pre-release environment for validation." : nil)
        let optionB = ExtensionFormOption(id: "environment-b", label: "Production", description: styled ? "The live environment used by customers." : nil)
        let form = ExtensionFormDescriptor(
            version: 1,
            title: "Choose deployment target",
            questions: [ExtensionFormQuestion(
                id: "environment",
                header: "Environment",
                question: "Which environments should receive the change?",
                context: styled ? "Choose the environment for this change. Your answers are kept if you close and reopen this form." : nil,
                options: [optionA, optionB],
                multiSelect: !styled,
                allowOther: true
            )] + (ProcessInfo.processInfo.arguments.contains("-tron-ask-user-multiple") ? [
                ExtensionFormQuestion(
                    id: "timing", question: "When should the change happen?",
                    options: [ExtensionFormOption(id: "now", label: "Now", description: nil),
                              ExtensionFormOption(id: "later", label: "Later", description: nil)],
                    multiSelect: false, allowOther: false
                )
            ] : []),
            allowCancel: allowCancel
        )
        self.form = form
        let interaction = ExtensionInteraction(
            id: "ask-user-interaction",
            hostEpoch: "hosted-ask-user-epoch",
            presentationRevision: 1,
            method: .form,
            title: form.title,
            form: form,
            owner: ExtensionOwner(id: "tron-ask-user", title: "Ask User", source: AskUserToolPresentation.tronSource),
            invocationId: "hosted-ask-user-invocation",
            operationId: "hosted-ask-user-operation"
        )
        self.interaction = interaction
        let answer = ExtensionFormAnswer(version: 1, answers: [
            ExtensionFormQuestionAnswer(
                questionId: "environment",
                optionIds: ["environment-a", "environment-b"],
                other: "A canary region"
            )
        ])
        self.answer = answer
        self.profile = GatewayProfile(
            id: "hosted-ask-user-profile",
            label: "Ask User fixture",
            host: "fixture.test",
            port: 9847,
            machineId: "hosted-ask-user-machine",
            deviceId: "hosted-ask-user-device"
        )
        let socket = HostedAskUserSocket(receipt: receipt)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in socket })
        let metadata = HostedAskUserMetadataStore(profile: profile)
        let tokens = HostedAskUserTokenStore(token: token)
        let profiles = GatewayProfileStore(metadata: metadata, tokens: tokens)
        let root = FileManager.default.temporaryDirectory.appending(path: "tron-hosted-ask-user-\(UUID().uuidString)")
        self.model = AppModel(
            client: client,
            profiles: profiles,
            cache: SnapshotCache(root: root),
            extensionInteractionDrafts: ExtensionInteractionDraftStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        self.snapshot = SessionSnapshot(
            sessionId: "hosted-ask-user-session",
            runtimeGeneration: "hosted-ask-user-runtime",
            revision: 1,
            eventSequence: 1,
            phase: .idle,
            name: "Ask User fixture",
            cwd: "/workspace",
            parentSessionId: nil,
            model: ModelRef(provider: "fixture", id: "fixture"),
            thinkingLevel: "medium",
            availableThinkingLevels: [],
            contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0, tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0,
            queuedItems: [],
            automaticCompactionEnabled: true,
            transcript: [],
            transcriptStart: nil,
            transcriptTotal: nil,
            streaming: nil,
            leafEntryId: nil,
            operation: nil,
            retry: nil,
            toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(
                version: 3,
                hostEpoch: interaction.hostEpoch,
                revision: interaction.presentationRevision,
                capabilities: [],
                diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [],
                pendingInteractions: [interaction]
            ),
            diagnostics: []
        )
    }
}

private final class HostedAskUserMetadataStore: GatewayProfileMetadataStoring {
    private let document: GatewayProfileDocument
    init(profile: GatewayProfile) { document = GatewayProfileDocument(profiles: [profile], selectedProfileID: profile.id) }
    func load() throws -> GatewayProfileDocument? { document }
    func save(_ document: GatewayProfileDocument) throws { }
}

private final class HostedAskUserTokenStore: GatewayTokenStoring {
    let token: String
    init(token: String) { self.token = token }
    func save(_ token: String, profileID: String) throws { }
    func read(profileID: String) throws -> String? { token }
    func delete(profileID: String) throws { }
}

private actor HostedAskUserSocket: GatewaySocketConnection {
    private let receipt: HostedAskUserFixtureReceipt
    private var inbound: [Data] = [Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":5,"minProtocolVersion":5,"machineId":"hosted-ask-user-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(receipt: HostedAskUserFixtureReceipt) { self.receipt = receipt }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        guard let frame = try? JSONDecoder.gateway.decode(JSONValue.self, from: data),
              let object = frame.objectValue,
              object["type"]?.stringValue == "request",
              let requestID = object["id"]?.stringValue,
              let method = object["method"]?.stringValue else { return }
        let params = object["params"]
        if method == "extension.respond" {
            let cancelled = params?.objectValue?["cancelled"]?.boolValue ?? false
            let value = params?.objectValue?["value"]
            let interactionID = params?.objectValue?["interactionId"]?.stringValue ?? ""
            let hostEpoch = params?.objectValue?["hostEpoch"]?.stringValue ?? ""
            let presentationRevision = params?.objectValue?["presentationRevision"]?.intValue ?? 0
            await receipt.record(
                cancelled: cancelled,
                value: value,
                interactionID: interactionID,
                hostEpoch: hostEpoch,
                presentationRevision: presentationRevision
            )
        }
        let result: JSONValue = method == "extension.respond"
            ? .object(["answered": .bool(true)])
            : .object([:])
        let response = try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(requestID), "ok": .bool(true), "result": result
        ]))
        enqueue(response)
    }

    func ping() async throws {
        guard !closed else { throw CancellationError() }
    }

    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }

    func close() async {
        closed = true
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func enqueue(_ data: Data) {
        if let receiver = receivers.first {
            receivers.removeFirst()
            receiver.resume(returning: data)
        } else {
            inbound.append(data)
        }
    }
}
#endif
