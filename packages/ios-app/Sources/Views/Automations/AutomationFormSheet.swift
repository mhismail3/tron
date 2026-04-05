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
            ScrollView {
                VStack(spacing: 24) {
                    Text("Tip: use @manage-automations in a session to create these conversationally.")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if let error = errorMessage {
                        errorBanner(error)
                    }
                    basicsSection
                    scheduleSection
                    payloadSection
                    advancedSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
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
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronCoral)
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.tronError)
            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.tronError)
        }
        .padding()
        .glassEffect(.regular.tint(Color.tronError.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Sections

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Basics", color: .tronCoral)

            SettingsCard(accent: .tronCoral) {
                glassTextField(icon: "tag", placeholder: "Name", text: $name)
                SettingsRowDivider()
                glassTextField(icon: "text.alignleft", placeholder: "Description (optional)", text: $description)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Schedule", color: .tronCoral)

            TronSegmentedControl(
                options: [("Interval", "every"), ("Cron", "cron"), ("One-Shot", "oneShot")],
                selection: $scheduleType,
                accent: .tronCoral
            )

            SettingsCard(accent: .tronCoral) {
                switch scheduleType {
                case "every":
                    SettingsRow(icon: "timer", label: "Every \(intervalMinutes) min", accentColor: .tronCoral) {
                        Text("\(intervalMinutes)")
                            .font(TronTypography.mono(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronCoral)
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                        TronStepper(value: $intervalMinutes, range: 1...10080, accent: .tronCoral)
                    }
                case "cron":
                    glassTextField(icon: "clock", placeholder: "Cron Expression", text: $cronExpression, codeFont: true)
                    SettingsRowDivider()
                    glassTextField(icon: "globe", placeholder: "Timezone", text: $cronTimezone)
                case "oneShot":
                    SettingsRow(icon: "calendar.badge.clock", label: "Run At", accentColor: .tronCoral) {
                        DatePicker("", selection: $oneShotDate)
                            .labelsHidden()
                    }
                default:
                    EmptyView()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scheduleType)

            SettingsCaption(text: scheduleHelpText)
        }
    }

    private var payloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Payload", color: .tronCoral)

            TronSegmentedControl(
                options: [("Shell", "shellCommand"), ("Agent", "agentTurn"), ("Webhook", "webhook")],
                selection: $payloadType,
                accent: .tronCoral
            )

            SettingsCard(accent: .tronCoral) {
                switch payloadType {
                case "shellCommand":
                    glassTextField(icon: "terminal.fill", placeholder: "Command", text: $shellCommand, codeFont: true, axis: .vertical)
                case "agentTurn":
                    glassTextField(icon: "brain", placeholder: "Prompt", text: $agentPrompt, axis: .vertical)
                case "webhook":
                    glassTextField(icon: "link", placeholder: "URL", text: $webhookUrl, codeFont: true, keyboard: .URL)
                    SettingsRowDivider()
                    SettingsRow(icon: "arrow.up.arrow.down", label: "Method", accentColor: .tronCoral) {
                        cyclingPicker(
                            values: ["GET", "POST", "PUT", "PATCH", "DELETE"],
                            labels: ["GET", "POST", "PUT", "PATCH", "DELETE"],
                            selection: $webhookMethod
                        )
                    }
                default:
                    EmptyView()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: payloadType)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Advanced", color: .tronCoral)

            SettingsCard(accent: .tronCoral) {
                SettingsRow(icon: "arrow.triangle.2.circlepath", label: "On Overlap", accentColor: .tronCoral) {
                    cyclingPicker(values: ["skip", "allow"], labels: ["Skip", "Allow"], selection: $overlapPolicy)
                }
                SettingsRowDivider()
                SettingsRow(icon: "exclamationmark.triangle", label: "On Misfire", accentColor: .tronCoral) {
                    cyclingPicker(values: ["skip", "runOnce"], labels: ["Skip", "Run Once"], selection: $misfirePolicy)
                }
                SettingsRowDivider()
                SettingsRow(icon: "arrow.counterclockwise", label: "Max Retries", accentColor: .tronCoral) {
                    Text("\(maxRetries)")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronCoral)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                    TronStepper(value: $maxRetries, range: 0...10, accent: .tronCoral)
                }
                SettingsRowDivider()
                SettingsRow(icon: "xmark.octagon", label: "Auto-Disable", accentColor: .tronCoral) {
                    Text(autoDisableAfter == 0 ? "Off" : "\(autoDisableAfter)")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronCoral)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                    TronStepper(value: $autoDisableAfter, range: 0...100, accent: .tronCoral)
                }
                SettingsRowDivider()
                glassTextField(icon: "tag", placeholder: "Tags (comma-separated)", text: $tags)
            }

            SettingsCaption(text: "Auto-disable turns off the job after consecutive failures. 0 means never.")
        }
    }

    // MARK: - Helpers

    private var scheduleHelpText: String {
        switch scheduleType {
        case "every": return "How often to run. Minimum 1 minute, maximum 7 days."
        case "cron": return "Standard 5-field cron expression (min hour dom mon dow)."
        case "oneShot": return "Runs exactly once at the specified time."
        default: return ""
        }
    }

    private func glassTextField(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        codeFont: Bool = false,
        axis: Axis = .horizontal,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(alignment: .center) {
            Image(systemName: icon)
                .font(codeFont
                    ? TronTypography.code(size: TronTypography.sizeBody)
                    : TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronCoral)
                .frame(width: 18)
            TextField(placeholder, text: text, axis: axis)
                .font(codeFont
                    ? TronTypography.code(size: TronTypography.sizeBody)
                    : TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(axis == .vertical ? 1...5 : 1...1)
                .keyboardType(keyboard)
                .autocorrectionDisabled(codeFont)
                .textInputAutocapitalization(codeFont ? .never : .sentences)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func cyclingPicker(
        values: [String],
        labels: [String],
        selection: Binding<String>
    ) -> some View {
        let currentIndex = values.firstIndex(of: selection.wrappedValue) ?? 0
        return Button {
            let next = (currentIndex + 1) % values.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selection.wrappedValue = values[next]
            }
        } label: {
            HStack(spacing: 4) {
                Text(labels[currentIndex])
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            }
            .foregroundStyle(.tronCoral)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronCoral.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
