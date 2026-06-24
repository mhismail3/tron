use super::support::*;

#[test]
fn provider_auth_model_roots_are_split_and_provider_native() {
    for (path, limit) in [
        (
            "packages/agent/src/domains/model/providers/factory/mod.rs",
            750,
        ),
        (
            "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
            750,
        ),
        (
            "packages/agent/src/domains/model/providers/openai/provider/tests/mod.rs",
            800,
        ),
        (
            "packages/agent/src/domains/auth/credentials/types/mod.rs",
            750,
        ),
        (
            "packages/agent/src/domains/model/providers/google/types/mod.rs",
            750,
        ),
        (
            "packages/agent/src/domains/model/providers/ollama/stream_handler/mod.rs",
            750,
        ),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-5 file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/agent/src/domains/model/providers/factory/tests.rs",
        "packages/agent/src/domains/model/providers/openai/message_converter/tests.rs",
        "packages/agent/src/domains/model/providers/openai/provider/tests/request.rs",
        "packages/agent/src/domains/auth/credentials/types/tests.rs",
        "packages/agent/src/domains/model/providers/google/types/models.rs",
        "packages/agent/src/domains/model/providers/ollama/stream_handler/tests.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-5 expected split owner missing: {path}"
        );
    }

    let provider_root = read_repo_file("packages/agent/src/domains/model/providers/mod.rs");
    assert!(
        provider_root.contains("Shared provider infrastructure stays under [`shared`]"),
        "provider root docs must state the shared/provider-native ownership boundary"
    );
    assert!(
        !provider_root.contains("compatibility aliases"),
        "provider root docs must not frame exports as compatibility aliases"
    );

    let openai_types =
        read_repo_file("packages/agent/src/domains/model/providers/openai/types/models/mod.rs");
    assert!(
        openai_types.contains("Provider aliases and snapshots accepted by the registry"),
        "OpenAI aliases must stay documented inside the provider model registry"
    );

    let allowed_alias_paths = [
        "packages/agent/src/domains/model/providers/openai/types/",
        "packages/agent/src/domains/model/providers/shared/provider.rs",
        "packages/agent/src/domains/model/providers/shared/retry.rs",
    ];
    for path in git_ls_files()
        .into_iter()
        .filter(|path| path.starts_with("packages/agent/src/domains/model/providers/"))
        .filter(|path| path.ends_with(".rs"))
    {
        let contents = read_repo_file(&path);
        for (line_number, line) in contents.lines().enumerate() {
            if line.to_ascii_lowercase().contains("alias") {
                assert!(
                    allowed_alias_paths
                        .iter()
                        .any(|allowed| path.starts_with(allowed)),
                    "provider alias reference outside catalog/type-helper boundary at {}:{}: {}",
                    path,
                    line_number + 1,
                    line
                );
            }
        }
    }
}
