import SwiftUI

// Installed via swift_app offer with feeds: ["ios-builds"]. The Gateway supplies
// a fresh immutable publisher snapshot on open/refresh; this app has no network.
@main
struct BuildsApp: App {
    var body: some Scene { WindowGroup { BuildsView() } }
}

struct Build: Identifiable {
    let id: String
    let title: String
    let notes: String
    let commit: String
    let branch: String
    let published: String
    let mode: String
    let size: String
    let status: String
    let digest: String
    let installURL: String
}

let feed = AppFeed.iosBuilds()
let builds = feed.builds.map { item in
    Build(id: item.id, title: item.title, notes: item.notes, commit: item.commit,
          branch: item.branch, published: item.time,
          mode: item.mode == "optimized" ? "Optimized" : "Fast debug",
          size: "\(item.bytes / 1048576) MB",
          status: item.id == feed.builds[0].id ? "Latest build" : "Older build",
          digest: item.sha256, installURL: item.installURL)
}

enum Mode: String, CaseIterable {
    case all = "All"
    case optimized = "Optimized"
    case fastDebug = "Fast debug"
}

struct BuildsView: View {
    @AppStorage("mode") private var mode = "All"
    @AppStorage("query") private var query = ""

    var shown: [Build] {
        builds.filter { build in
            let text = query.lowercased()
            return (mode == "All" || build.mode == mode) && (text.isEmpty || build.title.lowercased().contains(text) || build.branch.lowercased().contains(text) || build.commit.lowercased().contains(text))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title, branch or commit", text: $query)
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { value in
                            Text(value.rawValue).tag(value.rawValue)
                        }
                    }
                } footer: {
                    Text("Live builds · Pull to refresh").font(.caption).foregroundStyle(.secondary)
                }
                if feed.status == "unavailable" {
                    ContentUnavailableView("Builds unavailable", systemImage: "exclamationmark.triangle", description: Text(feed.message))
                } else if shown.isEmpty {
                    ContentUnavailableView("No builds", systemImage: "shippingbox", description: Text("No builds match this search or mode."))
                }
                ForEach(shown) { build in
                    NavigationLink {
                        BuildDetail(build: build)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(build.title).font(.headline)
                            Text(build.status).font(.caption).foregroundStyle(.secondary)
                            Text("\(build.published) · \(build.mode) · \(build.size)").font(.caption).foregroundStyle(.secondary)
                            Text(build.branch).font(.caption).foregroundStyle(.secondary)
                            Text(build.commit).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Builds")
        }
    }
}

struct BuildDetail: View {
    @Environment(\.openURL) private var openURL
    let build: Build
    var body: some View {
        List {
            Section {
                Text(build.title).font(.headline)
                Text(build.status).foregroundStyle(.secondary)
                Button("Install Build") { openURL(URL(string: build.installURL)!) }
            } footer: {
                Text("Opens the selected manifest · iOS asks before installing").font(.caption).foregroundStyle(.secondary)
            }
            Section("What to test") { Text(build.notes) }
            Section("Build") {
                Metadata(label: "Published", value: build.published)
                Metadata(label: "Mode", value: build.mode)
                Metadata(label: "Size", value: build.size)
                Metadata(label: "Branch", value: build.branch)
                Metadata(label: "Commit", value: build.commit)
                Metadata(label: "IPA SHA-256", value: build.digest)
            }
        }
        .navigationTitle("Build details")
    }
}

struct Metadata: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
