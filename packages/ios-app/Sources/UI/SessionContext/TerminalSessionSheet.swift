import SwiftUI
import SwiftTerm
import UIKit

@Observable
@MainActor
final class TerminalSessionController {
    struct RenderChunk: Identifiable { let id: UInt64; let bytes: [UInt8] }

    let sessionId: String
    private let repository: any TerminalRepository
    private(set) var terminal: TerminalSnapshot?
    private(set) var chunks: [RenderChunk] = []
    private(set) var status = "Connecting"
    private(set) var errorMessage: String?
    private(set) var attachmentId: String?
    private(set) var lastSequence: UInt64 = 0
    private(set) var rendererGeneration: UInt64 = 0
    private(set) var history: [TerminalSnapshot] = []
    private var resizeTask: Task<Void, Never>?
    private var didStart = false
    private var isAttaching = false
    private var processState = "connecting"
    private var pendingInputs: [(id: String, bytes: [UInt8])] = []
    private var pendingInputBytes = 0
    private var isFlushingInput = false
    private var isDetached = false

    init(sessionId: String, repository: any TerminalRepository) {
        self.sessionId = sessionId
        self.repository = repository
    }

    var workingDirectory: String { terminal?.workingDirectory ?? "Session workspace" }
    var isRunning: Bool { processState == "running" }

    func start() async {
        guard !didStart else { return }
        didStart = true
        isDetached = false
        errorMessage = nil
        repository.setUpdateHandler { [weak self] update in self?.receive(update) }
        guard repository.isSupported else {
            didStart = false
            errorMessage = "This Tron server does not support Terminal Mode."
            status = "Unavailable"
            return
        }
        do {
            let opened = try await repository.open(sessionId: sessionId, rows: 24, columns: 80)
            terminal = opened
            processState = opened.state
            status = "Attaching"
            try await attach()
            history = (try? await repository.list(sessionId: sessionId)) ?? []
            history.removeAll { $0.id == opened.id }
        } catch {
            didStart = false
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    func reconcile(continuity: EngineConnectionContinuity) async {
        guard continuity.isConnected else {
            if terminal != nil, processState == "running" { status = "Reconnecting" }
            return
        }
        if terminal == nil {
            await start()
            return
        }
        do {
            try await attach()
            await flushPendingInputs()
        } catch { status = "Reconnecting" }
    }

    func detach() async {
        resizeTask?.cancel()
        isDetached = true
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        repository.setUpdateHandler(nil)
        attachmentId = nil
    }

    func send(_ bytes: [UInt8]) {
        guard terminal != nil, processState == "running" else { return }
        guard pendingInputBytes + bytes.count <= 256 * 1024 else {
            errorMessage = "Terminal input is waiting for the connection to recover."
            return
        }
        pendingInputs.append((UUID().uuidString, bytes))
        pendingInputBytes += bytes.count
        Task { await flushPendingInputs() }
    }

    func resize(columns: Int, rows: Int) {
        guard let terminal, processState == "running" else { return }
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let rows = UInt16(exactly: max(5, min(rows, 200))),
                  let columns = UInt16(exactly: max(20, min(columns, 400))) else { return }
            try? await repository.resize(terminal: terminal, rows: rows, columns: columns)
        }
    }

    func terminate() {
        guard let terminal else { return }
        Task {
            do { try await repository.terminate(terminal); status = "Stopping" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func showHistory(_ selected: TerminalSnapshot) async {
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        attachmentId = nil
        terminal = selected
        processState = selected.state
        status = "Loading history"
        lastSequence = 0
        chunks.removeAll(keepingCapacity: true)
        rendererGeneration &+= 1
        do { try await attach() } catch {
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    func showLiveTerminal() async {
        do {
            let opened = try await repository.open(sessionId: sessionId, rows: 24, columns: 80)
            await showHistory(opened)
            history = try await repository.list(sessionId: sessionId)
            history.removeAll { $0.id == opened.id }
        } catch {
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    private func attach() async throws {
        guard let terminal, !isAttaching else { return }
        isAttaching = true
        defer { isAttaching = false }
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        let proposedAttachmentId = "termatt_\(UUID().uuidString)"
        attachmentId = proposedAttachmentId
        let attached: TerminalAttachmentSnapshot
        do {
            attached = try await repository.attach(
                terminalId: terminal.id,
                attachmentId: proposedAttachmentId,
                afterSequence: lastSequence
            )
        } catch {
            if attachmentId == proposedAttachmentId { attachmentId = nil }
            throw error
        }
        if attached.resetRequired {
            chunks.removeAll(keepingCapacity: true)
            rendererGeneration &+= 1
        }
        attachmentId = attached.attachmentId
        status = "Connected"
    }

    private func flushPendingInputs() async {
        guard !isFlushingInput, !isDetached, processState == "running", let terminal else { return }
        isFlushingInput = true
        defer { isFlushingInput = false }
        while !pendingInputs.isEmpty, !isDetached, processState == "running" {
            let input = pendingInputs[0]
            do {
                try await repository.write(input.bytes, terminal: terminal, inputId: input.id)
                if pendingInputs.first?.id == input.id {
                    pendingInputs.removeFirst()
                    pendingInputBytes -= input.bytes.count
                }
            } catch {
                status = "Reconnecting"
                return
            }
        }
    }

    private func receive(_ update: TerminalStreamUpdate) {
        switch update {
        case .status(let updateAttachmentId, let state, _, _):
            guard updateAttachmentId == attachmentId else { return }
            if let state, state != "catch_up_required" { processState = state }
            status = state == "catch_up_required" ? "Catching up" : (state ?? "Connected")
            if state == "catch_up_required" { Task { try? await attach() } }
        case .output(let updateAttachmentId, let sequence, let bytes):
            guard updateAttachmentId == attachmentId, sequence > lastSequence else { return }
            lastSequence = sequence
            chunks.append(RenderChunk(id: sequence, bytes: bytes))
            if chunks.count > 2_048 { chunks.removeFirst(chunks.count - 2_048) }
        }
    }
}

struct TerminalSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies
    @State private var controller: TerminalSessionController
    @State private var confirmTerminate = false

    init(sessionId: String, repository: any TerminalRepository) {
        _controller = State(
            initialValue: TerminalSessionController(
                sessionId: sessionId,
                repository: repository
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(controller.status == "Connected" ? Color.tronEmerald : Color.tronAmber).frame(width: 7, height: 7)
                    Text(controller.workingDirectory)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(controller.status)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)

                if let error = controller.errorMessage, controller.terminal == nil {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(error))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeTerminalView(controller: controller)
                        .id(controller.rendererGeneration)
                        .background(Color(uiColor: .systemBackground))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if !controller.isRunning {
                            Button("Open Live Terminal", systemImage: "terminal") {
                                Task { await controller.showLiveTerminal() }
                            }
                        }
                        if !controller.history.isEmpty {
                            Section("Recent terminals") {
                                ForEach(controller.history) { terminal in
                                    Button {
                                        Task { await controller.showHistory(terminal) }
                                    } label: {
                                        Label(terminal.exitedAt ?? terminal.createdAt, systemImage: "clock.arrow.circlepath")
                                    }
                                }
                            }
                        }
                        Button("Terminate Terminal", role: .destructive) { confirmTerminate = true }
                            .disabled(!controller.isRunning)
                    } label: { Image(systemName: "ellipsis") }
                }
                ToolbarItem(placement: .principal) { SheetTitle(title: "Terminal", color: .tronEmerald) }
                ToolbarItem(placement: .topBarTrailing) { SheetDismissButton(color: .tronEmerald) }
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
        .task { await controller.start() }
        .task(id: dependencies.connectionRepository.continuity) {
            await controller.reconcile(continuity: dependencies.connectionRepository.continuity)
        }
        .onDisappear { Task { await controller.detach() } }
        .confirmationDialog("Terminate this terminal?", isPresented: $confirmTerminate, titleVisibility: .visible) {
            Button("Terminate Terminal", role: .destructive) { controller.terminate() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The shell and its running process group will stop. Closing the sheet alone only detaches.") }
    }
}

private struct NativeTerminalView: UIViewRepresentable {
    let controller: TerminalSessionController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .systemBackground
        view.nativeForegroundColor = .label
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.controller = controller
        for chunk in controller.chunks where chunk.id > context.coordinator.lastFedSequence {
            view.feed(byteArray: chunk.bytes[...])
            context.coordinator.lastFedSequence = chunk.id
        }
    }

    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        var controller: TerminalSessionController
        var lastFedSequence: UInt64 = 0
        init(controller: TerminalSessionController) { self.controller = controller }
        @MainActor func send(source: TerminalView, data: ArraySlice<UInt8>) { controller.send(Array(data)) }
        @MainActor func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller.resize(columns: newCols, rows: newRows)
        }
        @MainActor func setTerminalTitle(source: TerminalView, title: String) {}
        @MainActor func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        @MainActor func scrolled(source: TerminalView, position: Double) {}
        @MainActor func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        @MainActor func bell(source: TerminalView) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        @MainActor func clipboardCopy(source: TerminalView, content: Data) { UIPasteboard.general.setData(content, forPasteboardType: "public.data") }
        @MainActor func clipboardRead(source: TerminalView) -> Data? { nil }
        @MainActor func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        @MainActor func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
