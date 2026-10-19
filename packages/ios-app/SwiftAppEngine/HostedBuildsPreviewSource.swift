#if HOSTED_TEST
/// Historical Builds.swift design recovered for #1319; install deliberately disabled.
/// Keep the delivered preview reproducible by exporting this raw source (docs/swift-apps.md).
package enum HostedBuildsPreviewSource {
    package static let source = #"""
    import SwiftUI
    
    @main
    struct BuildsApp: App {
        var body: some Scene {
            WindowGroup {
                ContentView()
            }
        }
    }
    
    struct Build: Identifiable {
        let id: String
        let title: String
        let notes: String
        let commit: String
        let branch: String
        let when: String
        let fastDebug: Bool
        let megabytes: Double
    }
    
    enum Mode: String, CaseIterable {
        case all = "All"
        case optimized = "Optimized"
        case fastDebug = "Fast debug"
    }
    
    let builds = [
            Build(id: "20261016T190200Z-515a0537c", title: "Preview 3 #1163 + #1155", notes: "#1163: amber warning from 60%, softened red at 100%, one-line columns.", commit: "515a0537c", branch: "preview/1163-1155", when: "Oct 16, 12:02 PM", fastDebug: false, megabytes: 22.8),
            Build(id: "20261016T185743Z-53f83f5c2", title: "Preview 2 #1163 + #1155", notes: "#1163 13bd3ef2a: softened reached-limit red; Home card columns drop 'used' so OpenCode Go's three windows share one line. #1155 dc6d94fd2 unchanged.", commit: "53f83f5c2", branch: "preview/1163-1155", when: "Oct 16, 11:57 AM", fastDebug: false, megabytes: 22.8),
            Build(id: "20261016T184838Z-317b0433e", title: "Preview #1163 + #1155: OpenCode Go monthly usage + Ask Question slide", notes: "OpenCode Go: monthly window on Providers row, detail sheet and Home usage card; a reached limit is red. Ask Question: questions slide in the swipe direction. Contains 1bc110340 (#1163) and dc6d94fd2 (#1155) on main 52a56322e.", commit: "317b0433e", branch: "preview/1163-1155", when: "Oct 16, 11:48 AM", fastDebug: false, megabytes: 22.8),
            Build(id: "20261016T095152Z-f95544a20", title: "#1112 continuous prose selection", notes: "Partial candidate f789f5e25: adjacent paragraphs/headings/lists; code/table/quote boundaries retained. Pending native regression and device approval.", commit: "f95544a20", branch: "fix/1112-ios-chat-selection-can-t", when: "Oct 16, 2:51 AM", fastDebug: true, megabytes: 35.5),
            Build(id: "20261016T093448Z-404ec8d3d", title: "Managed package identity (#626)", notes: "Unapproved UI candidate. Managed rows show name/version and no mutation menu once the matching Gateway change is installed. This phone build alone does not update the Gateway.", commit: "404ec8d3d", branch: "fix/626-the-tron-managed-pi-subagents", when: "Oct 16, 2:34 AM", fastDebug: true, megabytes: 35.5)
    ]
    
    struct ContentView: View {
        @State private var mode = Mode.all
        @State private var query = ""
    
        var shown: [Build] {
            builds.filter { build in
                let modeMatches = mode == .all || (mode == .fastDebug) == build.fastDebug
                let text = query.lowercased()
                return modeMatches && (text.isEmpty || build.title.lowercased().contains(text) || build.branch.lowercased().contains(text))
            }
        }
    
        var body: some View {
            NavigationStack {
                List {
                    Section {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Historical snapshot · Oct 16, 2026. Not live. Install is disabled in this preview.")
                    }
                    if shown.isEmpty {
                        ContentUnavailableView("No builds", systemImage: "shippingbox", description: Text("Nothing matches this filter."))
                    }
                    ForEach(shown) { build in
                        NavigationLink {
                            BuildDetail(build: build, isLatest: build.id == builds[0].id)
                        } label: {
                            BuildRow(build: build, isLatest: build.id == builds[0].id)
                        }
                    }
                }
                .navigationTitle("Tron builds")
                .accessibilityIdentifier("builds.preview")
                .searchable(text: $query, prompt: "Title or branch")
            }
        }
    }
    
    struct BuildRow: View {
        let build: Build
        let isLatest: Bool
    
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isLatest ? "star.circle.fill" : "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(isLatest ? .yellow : .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(build.title).font(.headline)
                    Text("\(build.when) · \(build.commit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(build.branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if build.fastDebug {
                    Text("DEBUG")
                        .font(.caption2)
                        .bold()
                        .padding(4)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    struct BuildDetail: View {
        let build: Build
        let isLatest: Bool
    
        var body: some View {
            List {
                Section {
                    Button("Install") { }
                        .disabled(true)
                } footer: {
                    Text("Preview only. No build or installation will start. Live build feeds are not available to chat-run Swift files.")
                }
                Section("What to test") {
                    Text(build.notes)
                }
                Section("Build") {
                    LabeledRow(label: "Published", value: build.when)
                    LabeledRow(label: "Commit", value: build.commit)
                    LabeledRow(label: "Branch", value: build.branch)
                    LabeledRow(label: "Mode", value: build.fastDebug ? "Fast debug" : "Optimized")
                    LabeledRow(label: "Size", value: String(format: "%.1f MB", build.megabytes))
                }
                if isLatest {
                    Section {
                        Label("Latest in snapshot", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .navigationTitle(build.title)
        }
    }
    
    struct LabeledRow: View {
        let label: String
        let value: String
    
        var body: some View {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
        }
    }
    """#
}
#endif
