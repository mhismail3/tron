import SwiftUI

/// Destination configuration remains in the UI; all upload and receipt ownership
/// belongs to the app-scoped background coordinator.
struct WatchRecordingDeliveryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfileID = UserDefaults.standard.string(forKey: "watchRecording.deliveryProfileID") ?? ""
    @State private var selectedRecordingID = ""
    @State private var coordinator = WatchRecordingDeliveryCoordinator.shared

    var body: some View {
        Form {
            Section("Recording destination") {
                if model.profiles.profiles.isEmpty {
                    Text("Pair a Mac Gateway before selecting a destination.")
                } else {
                    Picker("Paired Mac", selection: $selectedProfileID) {
                        Text("Choose a Mac").tag("")
                        ForEach(model.profiles.profiles.filter { $0.isEnabled && $0.deviceId != nil }) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                    .onChange(of: selectedProfileID) { _, value in
                        UserDefaults.standard.set(value, forKey: "watchRecording.deliveryProfileID")
                        configureWatch(profileID: value)
                    }
                }
                Text("Each recording stays pinned to the paired Mac chosen when recording starts. Changing this choice only affects future recordings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Assign an existing recording") {
                let recordings = unboundRecordingIDs
                if recordings.isEmpty {
                    Text("No unassigned recordings are waiting.").foregroundStyle(.secondary)
                } else {
                    Picker("Recording", selection: $selectedRecordingID) {
                        ForEach(recordings, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Assign to selected Mac") { assignExistingRecording() }
                        .disabled(selectedProfileID.isEmpty || selectedRecordingID.isEmpty)
                }
                Text("Assignments are stored separately from captured audio metadata. Changing the default does not move already assigned recordings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Delivery") {
                Text(coordinator.status)
                Button("Retry pending recordings") { coordinator.retry() }
            }
        }
        .navigationTitle("Watch Recordings")
        .task { coordinator.retry() }
    }

    private var unboundRecordingIDs: [String] {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("WatchRecordingInbox", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !$0.lastPathComponent.isEmpty
                && isUnboundRecording($0) }
            .map(\.lastPathComponent).sorted()
    }

    private func isUnboundRecording(_ folder: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("destination.json").path),
              let first = (try? WatchRecordingDeliveryCoordinator.recordingFiles(in: folder))?.first,
              let data = try? Data(contentsOf: first.metadataURL),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return metadata["destinationProfileId"] == nil || metadata["destinationProfileId"] is NSNull
    }

    private func assignExistingRecording() {
        guard let profile = model.profiles.profiles.first(where: { $0.id == selectedProfileID && $0.isEnabled }) else { return }
        do {
            try WatchRecordingInbox.shared.assignRecording(recordingID: selectedRecordingID, profileId: profile.id, machineId: profile.machineId)
            coordinator.retry()
        } catch {
            coordinator.setStatus("Could not save this recording assignment. Originals remain retained.")
        }
    }

    private func configureWatch(profileID: String) {
        guard let profile = model.profiles.profiles.first(where: { $0.id == profileID }) else { return }
        do {
            try WatchRecordingInbox.shared.configureRecordingDestination(profileId: profile.id, machineId: profile.machineId)
            coordinator.retry()
        } catch {
            coordinator.setStatus("Could not send the selected destination to Watch. Recordings remain retained.")
        }
    }
}
