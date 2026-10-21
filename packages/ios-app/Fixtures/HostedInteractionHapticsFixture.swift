#if HOSTED_TEST
import SwiftUI

/// Real shared interaction controls, not buttons that invoke the haptic seam.
/// Changing a binding externally proves that restoration is not user intent.
struct HostedInteractionHapticsFixture: View {
    @State private var activity = PresentationActivityCoordinator()
    @State private var enabled = false
    @State private var choice = "First"
    @State private var selected = ["First"]

    var body: some View {
        TronPresentationSurface(id: "fixture.interaction-haptics") { controls }
            .environment(\.tronPresentationActivityCoordinator, activity)
            .tronPresentation()
    }

    private var controls: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    TronToggleRow(icon: "power", title: "Enabled", isOn: $enabled)
                    TronToggleRow(icon: "power", title: "Unavailable", isEnabled: false, isOn: $enabled)
                    TronChoiceRow(icon: "circle", title: "Choice", choices: choices, selected: choice) { choice = $0 }
                    TronSelectionSheetRow(icon: "checklist", title: "Checklist", value: "Edit") {
                        TronChecklistPicker(title: "Checklist", choices: choices, selected: selected) { selected = $0 }
                    }
                    Text("Copy this message").padding(16)
                        .modifier(ChatMessageCopyMenu(text: "Copy this message"))
                        .accessibilityIdentifier("fixture.copy-message")
                    TronMarkdownView(text: "```swift\nlet answer = 42\n```", streaming: false)
                    Button("Restore values") { enabled = false; choice = "First"; selected = ["First"] }
                    Text("enabled:\(enabled) choice:\(choice) selected:\(selected.joined(separator: ","))")
                        .accessibilityIdentifier("fixture.values")
                    Text("haptics:\(TronHapticsProbe.shared.summary)").accessibilityIdentifier("fixture.haptics")
                }.padding(16)
            }
        }
        .tronPresentation()
    }

    private var choices: [TronChoice<String>] { [TronChoice(id: "First", label: "First"), TronChoice(id: "Second", label: "Second")] }
}
#endif
