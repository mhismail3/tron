import SwiftUI
import TronMobileCore

struct SessionSelectableTool: Identifiable, Hashable {
    let name: String
    let title: String
    let namespace: String
    let exposure: String
    var id: String { name }

    var selectable: Bool { exposure != "hidden" }
}

enum SessionToolPickerProjection {
    static func tools(from context: JSONValue?) -> [SessionSelectableTool] {
        (context?.objectValue?["availableTools"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
            return SessionSelectableTool(
                name: name,
                title: object["label"]?.stringValue ?? name,
                namespace: object["namespace"]?.stringValue ?? "General",
                exposure: object["exposure"]?.stringValue ?? "direct"
            )
        }.sorted {
            if $0.namespace != $1.namespace {
                return $0.namespace.localizedCaseInsensitiveCompare($1.namespace) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func activeNames(from context: JSONValue?) -> Set<String> {
        Set(context?.objectValue?["activeTools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

struct SessionToolPickerSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = true
    @State private var loadingRequest: UUID?
    @State private var saving = false
    @State private var errorMessage: String?

    private var tools: [SessionSelectableTool] { SessionToolPickerProjection.tools(from: model.context) }
    private var active: Set<String> { SessionToolPickerProjection.activeNames(from: model.context) }
    private var groups: [(String, [SessionSelectableTool])] {
        Dictionary(grouping: tools, by: \.namespace).map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        TronDocumentSheet(title: "Tools") {
            Group {
                if loading {
                    TronLoadingState(label: "Loading tools…", accent: .tronSessionTeal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tools.isEmpty {
                    TronInfoCard(icon: "wrench.and.screwdriver", text: "Tools are unavailable for this session.", accent: .tronSessionTeal)
                        .padding(18)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let errorMessage {
                                TronInfoCard(icon: "exclamationmark.triangle", text: errorMessage, accent: .tronError)
                            }
                            ForEach(groups, id: \.0) { namespace, items in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(namespace)
                                        .font(TronTypography.sheetSectionHeader)
                                        .foregroundStyle(Color.tronSessionTeal)
                                    ForEach(items) { tool in
                                        Button { toggle(tool) } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: active.contains(tool.name) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(active.contains(tool.name) ? Color.tronSessionTeal : Color.tronTextMuted)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(tool.title)
                                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                                        .foregroundStyle(Color.tronTextPrimary)
                                                    Text("\(tool.name) · \(tool.exposure)")
                                                        .font(TronTypography.code(size: TronTypography.sizeSecondary))
                                                        .foregroundStyle(Color.tronTextSecondary)
                                                        .lineLimit(1)
                                                }
                                                Spacer(minLength: 4)
                                                if !tool.selectable {
                                                    Text("Hidden")
                                                        .font(TronTypography.secondaryDescription)
                                                        .foregroundStyle(Color.tronTextMuted)
                                                }
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .tronScrollSurface(accent: .tronSessionTeal)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(saving || !tool.selectable)
                                        .accessibilityValue(active.contains(tool.name) ? "Enabled" : "Disabled")
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .tronScrollEdgeChrome()
                }
            }
        }
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .task(id: PresentationActivityTaskID(
            source: model.sessionContextRevision(for: sessionID),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            await load()
        }
    }

    private func load() async {
        guard presentationActivity.allowsPresentationPublication else { return }
        let request = UUID()
        loadingRequest = request
        loading = true
        await model.loadContext(sessionID: sessionID)
        guard !Task.isCancelled, loadingRequest == request,
              presentationActivity.allowsPresentationPublication else { return }
        loading = false
    }

    private func toggle(_ tool: SessionSelectableTool) {
        guard tool.selectable, !saving else { return }
        var next = active
        if next.contains(tool.name) { next.remove(tool.name) } else { next.insert(tool.name) }
        saving = true
        errorMessage = nil
        Task {
            do {
                try await model.setTools(Array(next).sorted(), sessionID: sessionID)
                await model.loadContext(sessionID: sessionID)
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}
