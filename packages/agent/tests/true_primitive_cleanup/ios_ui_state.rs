use super::support::*;

#[test]
fn ios_ui_state_roots_are_split_and_under_budget() {
    for (path, limit) in [
        (
            "packages/ios-app/Sources/UI/Settings/Shell/SettingsView.swift",
            575,
        ),
        (
            "packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel.swift",
            575,
        ),
        (
            "packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTests.swift",
            650,
        ),
        ("packages/ios-app/Sources/UI/Chat/Shell/ChatView.swift", 575),
        (
            "packages/ios-app/Tests/Session/Chat/ViewModel/ChatViewModelEventRoutingTests.swift",
            650,
        ),
        ("packages/ios-app/Sources/UI/Theme/TronColors.swift", 575),
        (
            "packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift",
            575,
        ),
        (
            "packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift",
            575,
        ),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-8 Swift file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/ios-app/Sources/UI/Settings/Shell/SettingsView+MainSection.swift",
        "packages/ios-app/Sources/UI/Settings/Shell/SettingsServerSupport.swift",
        "packages/ios-app/Sources/UI/Chat/Shell/ChatView+MessageList.swift",
        "packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel+RuntimeCallbacks.swift",
        "packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet+Sections.swift",
        "packages/ios-app/Sources/UI/Theme/TronThemeTokens.swift",
        "packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTypewriterTests.swift",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-8 expected split owner missing: {path}"
        );
    }

    let settings = read_repo_file("packages/ios-app/Sources/UI/Settings/Shell/SettingsView.swift");
    assert!(
        !settings.contains("func mainSettingsDestinationTile")
            && !settings.contains("func dangerActionTile"),
        "SettingsView.swift must not own main grid tile rendering"
    );

    let chat = read_repo_file("packages/ios-app/Sources/UI/Chat/Shell/ChatView.swift");
    assert!(
        !chat.contains("var messagesScrollView") && !chat.contains("func loadEarlierMessages"),
        "ChatView.swift must keep message-list and pagination view helpers in its extension owner"
    );

    let view_model =
        read_repo_file("packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel.swift");
    assert!(
        !view_model.contains("setupStreamingManagerCallbacks")
            && !view_model.contains("setupUIUpdateQueueCallback"),
        "ChatViewModel.swift must not own runtime callback wiring"
    );

    let settings_support =
        read_repo_file("packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift");
    assert!(
        !settings_support.contains("enum PairedServerMenuAction"),
        "SettingsSupport.swift must keep paired-server row/menu helpers in their own owner"
    );

    let model_picker =
        read_repo_file("packages/ios-app/Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift");
    assert!(
        !model_picker.contains("struct ProviderSection"),
        "ModelPickerSheet.swift must not own provider/family/model row sections"
    );

    let colors = read_repo_file("packages/ios-app/Sources/UI/Theme/TronColors.swift");
    assert!(
        !colors.contains("struct TintedColors")
            && !colors.contains("extension ShapeStyle where Self == Color"),
        "TronColors.swift must keep derived theme tokens outside the base palette file"
    );

    let streaming_tests =
        read_repo_file("packages/ios-app/Tests/Session/Chat/Messaging/StreamingManagerTests.swift");
    assert!(
        !streaming_tests.contains("testTypewriterRevealsTextGradually")
            && !streaming_tests.contains(&("no".to_owned() + "-op")),
        "StreamingManagerTests.swift must move typewriter coverage and avoid inactive-operation wording"
    );
}
