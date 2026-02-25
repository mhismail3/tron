import SwiftUI

/// Form sheet for creating a new cron job.
@available(iOS 26.0, *)
struct AutomationFormSheet: View {
    let rpcClient: RPCClient
    let onSaved: () -> Void
    let onCancel: () -> Void

    // Basic
    @State private var name = ""
    @State private var description = ""

    // Schedule
    @State private var scheduleType = "every"
    @State private var cronExpression = "0 * * * *"
    @State private var cronTimezone = "UTC"
    @State private var intervalMinutes = 60
    @State private var oneShotDate = Date().addingTimeInterval(3600)

    // Payload
    @State private var payloadType = "shellCommand"
    @State private var shellCommand = ""
    @State private var agentPrompt = ""
    @State private var webhookUrl = ""
    @State private var webhookMethod = "POST"

    // Advanced
    @State private var overlapPolicy = "skip"
    @State private var misfirePolicy = "skip"
    @State private var maxRetries = 0
    @State private var autoDisableAfter = 0
    @State private var tags = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                scheduleSection
                payloadSection
                advancedSection
            }
            .font(TronTypography.body)
            .scrollContentBackground(.hidden)
            .navigationTitle("New Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New Automation")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronCoral)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronCoral)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                            .tint(.tronCoral)
                    } else {
                        Button { createJob() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(name.isEmpty || !isPayloadValid ? .tronTextDisabled : .tronCoral)
                        }
                        .disabled(name.isEmpty || !isPayloadValid)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }

    // MARK: - Sections

    private var basicSection: some View {
        Section {
            TextField("Name", text: $name)
                .font(TronTypography.body)
            TextField("Description (optional)", text: $description)
                .font(TronTypography.body)
        } header: {
            Text("Basics")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronCoral)
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Type", selection: $scheduleType) {
                Text("Interval").tag("every")
                Text("Cron").tag("cron")
                Text("One-Shot").tag("oneShot")
            }
            .pickerStyle(.segmented)

            switch scheduleType {
            case "cron":
                TextField("Cron Expression", text: $cronExpression)
                    .font(TronTypography.code(size: TronTypography.sizeBody))
                TextField("Timezone", text: $cronTimezone)
                    .font(TronTypography.body)
            case "every":
                Stepper("Every \(intervalMinutes) minutes", value: $intervalMinutes, in: 1...10080)
                    .font(TronTypography.body)
            case "oneShot":
                DatePicker("Run At", selection: $oneShotDate)
                    .font(TronTypography.body)
            default:
                EmptyView()
            }
        } header: {
            Text("Schedule")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronCoral)
        }
    }

    private var payloadSection: some View {
        Section {
            Picker("Type", selection: $payloadType) {
                Text("Shell").tag("shellCommand")
                Text("Agent").tag("agentTurn")
                Text("Webhook").tag("webhook")
            }
            .pickerStyle(.segmented)

            switch payloadType {
            case "shellCommand":
                TextField("Command", text: $shellCommand, axis: .vertical)
                    .font(TronTypography.code(size: TronTypography.sizeBody))
                    .lineLimit(1...5)
            case "agentTurn":
                TextField("Prompt", text: $agentPrompt, axis: .vertical)
                    .font(TronTypography.body)
                    .lineLimit(1...5)
            case "webhook":
                TextField("URL", text: $webhookUrl)
                    .font(TronTypography.code(size: TronTypography.sizeBody))
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Picker("Method", selection: $webhookMethod) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .font(TronTypography.body)
            default:
                EmptyView()
            }
        } header: {
            Text("Payload")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronCoral)
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("On Overlap", selection: $overlapPolicy) {
                Text("Skip").tag("skip")
                Text("Allow").tag("allow")
            }
            .font(TronTypography.body)
            Picker("On Misfire", selection: $misfirePolicy) {
                Text("Skip").tag("skip")
                Text("Run Once").tag("runOnce")
            }
            .font(TronTypography.body)
            Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
                .font(TronTypography.body)
            Stepper("Auto-Disable After: \(autoDisableAfter) failures", value: $autoDisableAfter, in: 0...100)
                .font(TronTypography.body)
            TextField("Tags (comma-separated)", text: $tags)
                .font(TronTypography.body)
        } header: {
            Text("Advanced")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronCoral)
        }
    }

    // MARK: - Validation

    private var isPayloadValid: Bool {
        switch payloadType {
        case "shellCommand": return !shellCommand.isEmpty
        case "agentTurn": return !agentPrompt.isEmpty
        case "webhook": return !webhookUrl.isEmpty
        default: return false
        }
    }

    // MARK: - Create

    private func createJob() {
        isSaving = true

        let schedule: CronScheduleDTO = {
            switch scheduleType {
            case "cron":
                return .cron(expression: cronExpression, timezone: cronTimezone)
            case "oneShot":
                return .oneShot(at: DateParser.toISO8601(oneShotDate))
            default:
                return .every(intervalSecs: intervalMinutes * 60, anchor: nil)
            }
        }()

        let payload: CronPayloadDTO = {
            switch payloadType {
            case "agentTurn":
                return .agentTurn(prompt: agentPrompt, model: nil, workspaceId: nil, systemPrompt: nil)
            case "webhook":
                return .webhook(url: webhookUrl, method: webhookMethod, headers: nil, body: nil, timeoutSecs: nil)
            default:
                return .shellCommand(command: shellCommand, workingDirectory: nil, timeoutSecs: nil)
            }
        }()

        let parsedTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let jobParams = CronCreateJobParams(
            name: name,
            description: description.isEmpty ? nil : description,
            enabled: true,
            schedule: schedule,
            payload: payload,
            delivery: nil,
            overlapPolicy: overlapPolicy,
            misfirePolicy: misfirePolicy,
            maxRetries: maxRetries > 0 ? maxRetries : nil,
            autoDisableAfter: autoDisableAfter > 0 ? autoDisableAfter : nil,
            tags: parsedTags.isEmpty ? nil : parsedTags,
            workspaceId: nil
        )

        Task {
            do {
                _ = try await rpcClient.cron.createJob(jobParams)
                await MainActor.run {
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
