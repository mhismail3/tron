#if HOSTED_TEST
import SwiftUI

/// `-tron-subsheet-reliability-fixture` (#1695): one managed parent sheet whose
/// rows open an item child and a Boolean child through the shared presenters.
/// The child's controls stand in for requests the user cannot time by touch:
/// re-requesting a child N ms into its dismissal, requesting the parent's
/// other presenter while a child still covers it (UIKit defers that
/// presentation), and closing the parent before a deferred child appears.
struct HostedSubsheetReliabilityFixture: View {
    @State private var activity = PresentationActivityCoordinator()
    @State private var parent = false
    @State private var neverAppeared = 0

    var body: some View {
        TronPresentationSurface(id: "fixture.subsheet-reliability") {
            NavigationStack {
                VStack(spacing: 16) {
                    Button("Open parent") { parent = true }.accessibilityIdentifier("fixture.open-parent")
                    Text("never-appeared:\(neverAppeared)").accessibilityIdentifier("fixture.never-appeared")
                    Text("haptics:\(TronHapticsProbe.shared.count(.sheetPresented))").accessibilityIdentifier("fixture.root-sheet-haptics")
                }
                .tronManagedSheet(isPresented: $parent, identity: "fixture.parent") {
                    HostedSubsheetParent { parent = false }
                }
            }
        }
        .environment(\.tronPresentationActivityCoordinator, activity)
        .tronPresentation()
        .onAppear {
            HostedPresentationProbe.record = { event, _ in
                if event == "never-appeared" { neverAppeared += 1 }
            }
        }
    }
}

private struct HostedSubsheetItem: Identifiable, Hashable {
    let id: String
}

private struct HostedSubsheetParent: View {
    let closeParent: () -> Void
    @PresentationState private var item: HostedSubsheetItem?
    @PresentationState private var flag = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ForEach(["a", "b"], id: \.self) { id in
                    Button("Row \(id)") { item = HostedSubsheetItem(id: id) }.accessibilityIdentifier("fixture.row-\(id)")
                }
                Button("Flag row") { flag = true }.accessibilityIdentifier("fixture.flag-row")
                Text("item:\(item?.id ?? "nil") flag:\(flag)").accessibilityIdentifier("fixture.child-state")
                Text("haptics:\(TronHapticsProbe.shared.count(.sheetPresented))").accessibilityIdentifier("fixture.sheet-haptics")
                Spacer()
            }
            .padding()
            .navigationTitle("Parent")
        }
        .presentationDetents([.large])
        .tronManagedSheet(item: $item, identity: { "fixture.item.\($0.id)" }) { value in
            HostedSubsheetChild(title: "Item \(value.id)", closeParent: closeParent) { delay in
                rerequest(after: delay, close: { item = nil }, open: { item = HostedSubsheetItem(id: value.id == "a" ? "b" : "a") })
            } requestSibling: { flag = true }
        }
        .tronManagedSheet(isPresented: $flag, identity: "fixture.flag") {
            HostedSubsheetChild(title: "Flag", closeParent: closeParent) { delay in
                rerequest(after: delay, close: { flag = false }, open: { flag = true })
            } requestSibling: { item = HostedSubsheetItem(id: "a") }
        }
    }

    private func rerequest(after delay: Int, close: () -> Void, open: @escaping () -> Void) {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            open()
        }
    }
}

private struct HostedSubsheetChild: View {
    let title: String
    let closeParent: () -> Void
    let rerequest: (Int) -> Void
    let requestSibling: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(title).accessibilityIdentifier("fixture.child-title")
            Button("Close child") { dismiss() }.accessibilityIdentifier("fixture.child-close")
            Button("Request sibling") { requestSibling() }.accessibilityIdentifier("fixture.request-sibling")
            Button("Request sibling and close parent") { requestSibling(); closeParent() }
                .accessibilityIdentifier("fixture.request-sibling-close-parent")
            ForEach([0, 150, 300, 450, 700], id: \.self) { delay in
                Button("Re-request after \(delay) ms") { rerequest(delay) }.accessibilityIdentifier("fixture.rerequest-\(delay)")
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
