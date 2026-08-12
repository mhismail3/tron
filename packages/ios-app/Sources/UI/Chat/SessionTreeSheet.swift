import SwiftUI

struct SessionTreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SessionTreeNode?
    @State private var labelNode: SessionTreeNode?
    @State private var label = ""

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                if model.sessionTree.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                            .foregroundStyle(Color.tronTextMuted)
                        Text("No history available")
                            .font(TronTypography.headline)
                        Text("Refresh after the session finishes loading.")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)
                    .padding(20)
                } else {
                    OutlineGroup(model.sessionTree, children: \.outlineChildren) { node in
                        TreeNodeRow(node: node, leafID: model.selectedSnapshot?.leafEntryId) {
                            selected = node
                        } bookmark: {
                            label = node.label ?? ""
                            labelNode = node
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Session History") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task {
                if let id = model.selectedSessionID { try? await model.openSession(id) }
                await model.loadTree()
            }
            .refreshable { await model.loadTree() }
            .sheet(item: $selected) { node in NavigationSheet(node: node) }
            .alert("Bookmark", isPresented: Binding(
                get: { labelNode != nil },
                set: { if !$0 { labelNode = nil } }
            )) {
                TextField("Label", text: $label)
                Button("Save") {
                    guard let node = labelNode else { return }
                    Task {
                        do { try await model.setLabel(entryID: node.id, label: label) }
                        catch { model.lastError = error.localizedDescription }
                    }
                    labelNode = nil
                }
                if labelNode?.label != nil {
                    Button("Remove", role: .destructive) {
                        guard let node = labelNode else { return }
                        Task {
                            do { try await model.setLabel(entryID: node.id, label: nil) }
                            catch { model.lastError = error.localizedDescription }
                        }
                        labelNode = nil
                    }
                }
                Button("Cancel", role: .cancel) { labelNode = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private struct TreeNodeRow: View {
    let node: SessionTreeNode
    let leafID: String?
    let select: () -> Void
    let bookmark: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(node.id == leafID ? Color.tronEmerald : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.label ?? node.preview.ifEmpty(node.kind.humanized))
                        .font(TronTypography.body)
                        .lineLimit(2)
                        .foregroundStyle(Color.tronTextPrimary)
                    if node.label != nil, !node.preview.isEmpty {
                        Text(node.preview).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary).lineLimit(1)
                    }
                }
                Spacer()
                if node.id == leafID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tronEmerald)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: node.id == leafID ? .tronEmerald : .tronSlate, tintOpacity: node.id == leafID ? 0.16 : 0.08, interactive: true)
        .contextMenu { Button("Edit Bookmark", systemImage: "bookmark", action: bookmark) }
    }

    private var icon: String {
        switch node.kind {
        case "message": "bubble.left"
        case "bash": "terminal"
        case "compaction": "arrow.down.right.and.arrow.up.left"
        case "branchSummary": "arrow.triangle.branch"
        case "modelChange": "cpu"
        case "thinkingChange": "brain"
        case "label": "bookmark"
        default: "puzzlepiece.extension"
        }
    }
}

private struct NavigationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let node: SessionTreeNode
    @State private var summarize = false
    @State private var instructions = ""
    @State private var replaceInstructions = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    TronSettingsGroup("Selected Point") {
                        TronValueRow(icon: "point.3.connected.trianglepath.dotted", title: node.preview.ifEmpty(node.kind.humanized), detail: node.label)
                    }
                    TronSettingsGroup("Abandoned Branch", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            TronToggleRow(icon: "text.bubble", title: "Create a branch summary", accent: .tronPurple, isOn: $summarize)
                            if summarize {
                                TronSettingsDivider(accent: .tronPurple)
                                VStack(spacing: 12) {
                                    TextField("Optional summary instructions", text: $instructions, axis: .vertical)
                                        .lineLimit(3...8)
                                        .tronField()
                                    TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Replace default instructions", accent: .tronPurple, isOn: $replaceInstructions)
                                }
                                .padding(12)
                            }
                        }
                    }
                    Button(working ? "Navigating…" : "Continue From Here") {
                        working = true
                        Task {
                            defer { working = false }
                            do {
                                _ = try await model.navigate(
                                    entryID: node.id,
                                    summarize: summarize,
                                    instructions: instructions.isEmpty ? nil : instructions,
                                    replaceInstructions: replaceInstructions
                                )
                                dismiss()
                            } catch { model.lastError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(working || node.id == model.selectedSnapshot?.leafEntryId)
                }
                .padding(20)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Navigate History") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private extension SessionTreeNode {
    var outlineChildren: [SessionTreeNode]? { children.isEmpty ? nil : children }
}

private extension String {
    var humanized: String {
        replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
