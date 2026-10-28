import SwiftUI

// Visual proposal only. The installed version will receive declared ios-builds
// values from the Gateway; this file deliberately has no network/install access.
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
}

let builds = [
    Build(id: "latest", title: "Apps installation and live builds", notes: "Install Builds from its Swift artifact. Open it from Apps and check the newest build and its metadata. This is synthetic review data, not a published build.", commit: "3028379fc5c26bea4bdf0c9fe0c9423fc462eaaf", branch: "feat/apps-install-flow", published: "2026-10-28 08:00 UTC", mode: "Optimized", size: "22.8 MB", status: "Latest build", digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    Build(id: "older", title: "Shared list rows and theme inheritance", notes: "Check Apps in light and dark appearance. Titles and technical metadata should wrap at larger text sizes.", commit: "86bf7820f", branch: "fix/shared-list-rows", published: "2026-10-27 19:30 UTC", mode: "Fast debug", size: "35.5 MB", status: "Older build", digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
]

enum Mode: String, CaseIterable {
    case all = "All"
    case optimized = "Optimized"
    case fastDebug = "Fast debug"
}

struct BuildsView: View {
    @State private var mode = Mode.all
    @State private var query = ""

    var shown: [Build] {
        builds.filter { build in
            let text = query.lowercased()
            return (mode == .all || build.mode == mode.rawValue) && (text.isEmpty || build.title.lowercased().contains(text) || build.branch.lowercased().contains(text) || build.commit.lowercased().contains(text))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title, branch or commit", text: $query)
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                } footer: {
                    Text("Sample builds · Not live").font(.caption).foregroundStyle(.secondary)
                }
                if shown.isEmpty {
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
    let build: Build
    var body: some View {
        List {
            Section {
                Text(build.title).font(.headline)
                Text(build.status).foregroundStyle(.secondary)
                Button("Install Build") { }
                    .disabled(true)
            } footer: {
                Text("Preview only · Install disabled").font(.caption).foregroundStyle(.secondary)
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
