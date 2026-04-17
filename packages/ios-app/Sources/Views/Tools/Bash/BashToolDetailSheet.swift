import SwiftUI

// MARK: - Bash Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Bash tool results.
/// Shows the command, execution status, exit code, and output with
/// line numbers, ANSI stripping, and smart display-length capping.
@available(iOS 26.0, *)
struct BashToolDetailSheet: View {
    let data: CommandToolChipData
    var rpcClient: RPCClient?
    var sessionId: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAllLines = false
    @State private var actionTaken = false

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var command: String {
        ToolArgumentParser.command(from: data.arguments)
    }

    private var commandDescription: String? {
        ToolArgumentParser.string("description", from: data.arguments)
    }

    private var timeoutMs: Int? {
        ToolArgumentParser.integer("timeout", from: data.arguments)
    }

    // MARK: - Phase 2 Argument Extraction

    private var shell: String? {
        ToolArgumentParser.string("shell", from: data.arguments)
            ?? BashDetailsHelper.shell(from: data.details)
    }

    private var isInteractive: Bool {
        ToolArgumentParser.boolean("interactive", from: data.arguments) == true
            || BashDetailsHelper.isInteractive(from: data.details)
    }

    private var stdinContent: String? {
        ToolArgumentParser.string("stdin", from: data.arguments)
    }

    private var envVars: [String: String]? {
        ToolArgumentParser.dictionary("env", from: data.arguments)
    }

    private var sandboxMode: String? {
        BashDetailsHelper.sandboxMode(from: data.arguments)
    }

    private var ptyInputPairs: [[String: String]]? {
        if let fromArgs = ToolArgumentParser.objectArray("ptyInput", from: data.arguments) {
            return BashDetailsHelper.redactPtyInput(fromArgs)
        }
        if let fromDetails = BashDetailsHelper.ptyInput(from: data.details) {
            return fromDetails // already redacted server-side
        }
        return nil
    }

    // MARK: - Result Analysis

    private var exitCode: Int? {
        BashDetailsHelper.exitCode(from: data.details)
    }

    private var isBlocked: Bool {
        BashDetailsHelper.isBlocked(from: data.details)
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.details?.bool("truncated") == true)
    }

    private var cleanOutput: String {
        let source = data.result ?? data.streamingOutput ?? ""
        return BashOutputHelpers.cleanForDisplay(source)
    }

    private var outputLines: [String] {
        guard !cleanOutput.isEmpty else { return [] }
        return cleanOutput.components(separatedBy: "\n")
    }

    private var outputLineCount: Int {
        outputLines.count
    }

    private var shouldCollapse: Bool {
        outputLineCount > BashOutputHelpers.collapseThreshold
    }

    private var displayLines: [(index: Int, content: String)] {
        if shouldCollapse && !showAllLines {
            return BashOutputHelpers.collapsedLines(from: outputLines)
        }
        return outputLines.enumerated().map { ($0.offset, $0.element) }
    }

    private var hiddenLineCount: Int {
        guard shouldCollapse && !showAllLines else { return 0 }
        return outputLineCount - BashOutputHelpers.headLines - BashOutputHelpers.tailLines
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Bash",
            iconName: "terminal",
            accent: .tronEmerald,
        ) {
            contentBody
        } leadingToolbar: {
            if isJobActive && !actionTaken {
                Button { backgroundJob() } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.orange.opacity(0.8))
                }
                .accessibilityLabel("Background")

                Button { cancelJob() } label: {
                    Image(systemName: "stop.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .accessibilityLabel("Interrupt")
            }
        }
        .onAppear {
            subscribeToOutputIfNeeded()
        }
        .onDisappear {
            unsubscribeFromOutput()
        }
    }

    private func subscribeToOutputIfNeeded() {
        guard let processId, let rpcClient, let sessionId, isJobActive else { return }
        Task {
            try? await rpcClient.job.subscribe(jobId: processId, sessionId: sessionId)
        }
    }

    private func unsubscribeFromOutput() {
        guard let processId, let rpcClient else { return }
        Task {
            try? await rpcClient.job.unsubscribe(jobId: processId)
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                BashCommandSection(command: command, commandDescription: commandDescription, tint: tint)
                    .sheetSection()
                statusRow
                    .sheetSection()

                if let stdin = stdinContent, !stdin.isEmpty {
                    BashStdinSection(content: stdin, tint: tint)
                        .sheetSection()
                }
                if let env = envVars, !env.isEmpty {
                    BashEnvSection(env: env, tint: tint)
                        .sheetSection()
                }
                if let pairs = ptyInputPairs, !pairs.isEmpty {
                    BashPtyInputSection(pairs: pairs, tint: tint)
                        .sheetSection()
                }

                if isBackgroundedProcess {
                    // Process was auto-backgrounded — show streaming output + action buttons
                    runningSection
                        .sheetSection()
                } else {
                    switch data.status {
                    case .success:
                        if outputLines.isEmpty {
                            ToolEmptyState(title: "Output", icon: "text.page.slash", message: "No output", accent: .tronEmerald, tint: tint)
                                .sheetSection()
                        } else {
                            outputSection
                                .sheetSection()
                        }
                    case .error:
                        if isBlocked {
                            BashBlockedSection(result: data.result, colorScheme: colorScheme)
                                .sheetSection()
                        } else if outputLines.isEmpty {
                            if let result = data.result {
                                errorFallbackSection(result)
                                    .sheetSection()
                            }
                        } else {
                            outputSection
                                .sheetSection()
                        }
                    case .running:
                        runningSection
                            .sheetSection()
                    }
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: nil) {
            if let code = exitCode, code != 0 {
                ToolInfoPill(icon: "xmark.circle", label: "Exit \(code)", color: .tronError)
            }
            if let sh = shell, sh != "bash" {
                ToolInfoPill(icon: "apple.terminal", label: sh, color: .tronIndigo)
            }
            if isInteractive {
                ToolInfoPill(icon: "rectangle.connected.to.line.below", label: "PTY", color: .tronTeal)
            }
            if let sandbox = sandboxMode {
                ToolInfoPill(icon: "lock.shield", label: sandbox == "docker" ? "Docker" : "Sandbox", color: .tronAmber)
            }
            if let ms = data.durationMs {
                ToolDurationBadge(durationMs: ms)
            }
            if stdinContent != nil {
                ToolInfoPill(icon: "arrow.right.doc", label: "stdin")
            }
            if outputLineCount > 0 {
                ToolInfoPill(icon: "text.line.last.and.arrowtriangle.forward", label: "\(outputLineCount) lines")
            }
            if isTruncated {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
            if isBackgroundedProcess {
                ToolInfoPill(icon: "arrow.down.to.line", label: "Backgrounded", color: .orange)
            }
            if actionTaken && data.status == .error {
                ToolInfoPill(icon: "stop.fill", label: "Interrupted", color: .red)
            }
        }
    }

    // MARK: - Output Section

    private var outputSection: some View {
        let lineNumWidth = BashOutputHelpers.lineNumberWidth(lineCount: outputLineCount)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: data.result ?? "", accent: .tronEmerald)
            }

            BashOutputLinesView(
                lines: displayLines,
                lineNumWidth: lineNumWidth,
                tint: tint,
                shouldCollapse: shouldCollapse,
                showAllLines: showAllLines,
                hiddenLineCount: hiddenLineCount,
                onExpand: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllLines = true
                    }
                }
            )
        }
    }

    // MARK: - Error Fallback Section

    private func errorFallbackSection(_ result: String) -> some View {
        let classification = BashErrorClassifier.classify(details: data.details)
        return ToolClassifiedErrorSection(errorMessage: result, classification: classification, colorScheme: colorScheme) {
            Text(result)
                .font(TronTypography.codeContent)
                .foregroundStyle(TintedColors(accent: .tronError, colorScheme: colorScheme).body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            BashStreamingOutputView(output: output, tint: tint)
        } else {
            ToolRunningSpinner(title: "Output", accent: .tronEmerald, tint: tint, actionText: "Running command...")
        }
    }

    // MARK: - Job State

    private var processId: String? {
        BashDetailsHelper.processId(from: data.details)
    }

    private var isBackgroundedProcess: Bool {
        BashDetailsHelper.isBackgrounded(from: data.details)
    }

    private var isJobActive: Bool {
        data.status == .running || isBackgroundedProcess
    }

    // MARK: - Job Actions

    private func backgroundJob() {
        guard let processId, let rpcClient, let sessionId else { return }
        actionTaken = true
        Task {
            try? await rpcClient.job.background(jobId: processId, sessionId: sessionId)
        }
    }

    private func cancelJob() {
        guard let processId, let rpcClient, let sessionId else { return }
        actionTaken = true
        Task {
            try? await rpcClient.job.cancel(jobId: processId, sessionId: sessionId)
        }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Bash - Success") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b1", toolName: "Bash", normalizedName: "bash", icon: "terminal",
            iconColor: .tronEmerald, displayName: "Bash", summary: "git status --short",
            status: .success, durationMs: 45,
            arguments: "{\"command\": \"git status --short\", \"description\": \"Show working tree status\"}",
            result: " M README.md\n M src/index.ts\nA  packages/new-feature/lib.ts",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Error") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b4", toolName: "Bash", normalizedName: "bash", icon: "terminal",
            iconColor: .tronEmerald, displayName: "Bash", summary: "cargo build",
            status: .error, durationMs: 3400,
            arguments: "{\"command\": \"cargo build\"}",
            result: "Command failed with exit code 1:\nerror[E0308]: mismatched types",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Blocked") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b5", toolName: "Bash", normalizedName: "bash", icon: "terminal",
            iconColor: .tronEmerald, displayName: "Bash", summary: "rm -rf /",
            status: .error, durationMs: 1,
            arguments: "{\"command\": \"rm -rf /\"}",
            result: "Command blocked for safety: Potentially destructive command pattern detected",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Streaming") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b8", toolName: "Bash", normalizedName: "bash", icon: "terminal",
            iconColor: .tronEmerald, displayName: "Bash", summary: "npm install",
            status: .running, durationMs: nil,
            arguments: "{\"command\": \"npm install\"}",
            result: nil, isResultTruncated: false,
            streamingOutput: "added 142 packages in 3.2s\nresolving dependencies..."
        )
    )
}
#endif
