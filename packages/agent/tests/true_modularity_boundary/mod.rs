//! Living source-backed dependency-boundary guards.

mod support;

use std::path::Path;

use support::*;

#[test]
fn agent_loop_uses_model_responder_boundary() {
    assert!(
        repo_path("packages/agent/src/domains/model/responder/mod.rs").exists(),
        "domains::model must expose an internal responder boundary module"
    );

    let leaks = rust_source_lines("packages/agent/src/domains/agent")
        .into_iter()
        .filter(|line| {
            line.contains("domains::model::providers")
                || line.contains("ProviderFactory")
                || line.contains("ProviderHealthTracker")
                || line.contains("dyn Provider")
                || line.contains("ProviderStreamOptions")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "agent loop must depend on domains::model responder APIs, not provider internals:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn provider_internals_do_not_escape_model_domain() {
    let provider_docs = read_repo_file("packages/agent/src/domains/model/providers/mod.rs");
    assert!(
        provider_docs.contains(
            "Depended on by: `domains::model::responder`, model routing/catalog code,\n//! and app bootstrap only as the composition/root startup path."
        ),
        "provider root docs must name the approved dependents without broadening provider-internal access"
    );
    assert!(
        !provider_docs.contains("Depended on by: the agent loop")
            && !provider_docs.contains("agent loop, runtime bootstrap")
            && !provider_docs.contains("agent loop depends on provider internals"),
        "provider root docs must not claim the agent loop depends on provider internals"
    );

    let allowed_prefixes = [
        "packages/agent/src/domains/model/",
        "packages/agent/src/app/bootstrap/",
    ];
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("domains::model::providers::")
                || line.contains("pub use providers::")
                || line.contains("ProviderError")
                || line.contains("ProviderFactory")
                || line.contains("ProviderHealthTracker")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "provider internals may not escape domains::model except documented composition roots:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn engine_facade_is_the_only_cross_module_engine_api() {
    let allowed_prefixes = [
        "packages/agent/src/engine/",
        "packages/agent/src/app/bootstrap/",
        "packages/agent/src/domains/registration/",
    ];
    let banned_segments = [
        "crate::engine::authority::",
        "crate::engine::catalog::",
        "crate::engine::durability::",
        "crate::engine::invocation::",
        "crate::engine::kernel::",
        "crate::engine::primitives::",
        "crate::engine::runtime::",
    ];

    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| banned_segments.iter().any(|needle| line.contains(needle)))
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "cross-module engine users must import the approved engine facade, not internals:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn domain_workers_expose_contracts_not_services() {
    let module_dependencies =
        read_repo_file("packages/agent/src/domains/module_dependencies/mod.rs");
    assert!(
        !module_dependencies.contains("pub(crate) mod contract")
            && !module_dependencies.contains("pub(crate) use crate::engine"),
        "module-dependency contracts and engine identifiers must stay domain-private"
    );

    let allowed_prefixes = [
        "packages/agent/src/domains/",
        "packages/agent/src/app/bootstrap/",
    ];
    let service_leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("::handlers::")
                || line.contains("::service::")
                || line.contains("::deps::")
                || line.contains("::operations::")
        })
        .collect::<Vec<_>>();

    assert!(
        service_leaks.is_empty(),
        "runtime/transport/app code must use domain contracts or composition roots, not domain services:\n{}",
        service_leaks.join("\n")
    );

    let public_worker_constructors = rust_source_lines("packages/agent/src/domains")
        .into_iter()
        .filter(|line| {
            line.contains("pub fn worker_module")
                || line.contains("pub fn worker_modules")
                || line.contains("pub fn domain_worker_module")
                || line.contains("pub fn register_domain_workers_for_context")
        })
        .collect::<Vec<_>>();

    assert!(
        public_worker_constructors.is_empty(),
        "domain worker registration and worker-module constructors must stay crate-private:\n{}",
        public_worker_constructors.join("\n")
    );

    let registration_call_leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| line.contains("register_domain_workers_for_context("))
        .filter(|line| {
            let path = path_from_line(line);
            path != "packages/agent/src/domains/registration/mod.rs"
                && path != "packages/agent/src/transport/runtime/setup.rs"
        })
        .collect::<Vec<_>>();

    assert!(
        registration_call_leaks.is_empty(),
        "domain worker registration must be centralized behind transport runtime setup:\n{}",
        registration_call_leaks.join("\n")
    );
}

#[test]
fn state_stores_are_owner_private() {
    let allowed_prefixes = [
        "packages/agent/src/app/bootstrap/",
        "packages/agent/src/domains/auth/",
        "packages/agent/src/domains/session/event_store/",
        "packages/agent/src/domains/settings/profile/",
        "packages/agent/src/engine/authority/",
        "packages/agent/src/engine/durability/",
        "packages/agent/src/engine/invocation/host/",
        "packages/agent/src/engine/primitives/",
        "packages/agent/src/shared/observability/",
        "packages/agent/src/shared/server/error_mapping/mod.rs",
        "packages/agent/src/shared/storage/",
    ];
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("event_store::sqlite")
                || line.contains("rusqlite::")
                || line.contains("Sqlite")
                || line.contains("repositories::")
                || line.contains("storage::")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "state and storage backends must stay behind owner repository/service contracts:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn transport_is_adapter_only() {
    let leaks = rust_source_lines("packages/agent/src/transport")
        .into_iter()
        .filter(|line| {
            line.contains("domains::agent::")
                || line.contains("domains::session::event_store::sqlite")
                || line.contains("domains::model::providers")
                || line.contains("engine::durability::")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "transport code must frame requests and map protocol only:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn shared_protocol_does_not_depend_on_domains() {
    let leaks = rust_source_lines("packages/agent/src/shared/protocol")
        .into_iter()
        .filter(|line| line_has_identifier(line, "domains"))
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "shared protocol must remain domain-neutral:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn ios_ui_uses_repositories_not_engine_transport() {
    let banned_identifiers = [
        "EngineClient",
        "WebSocket",
        "EngineProtocolTypes",
        "ServerSettings",
        "ServerSettingsUpdate",
        "AuthState",
        "AuthUpdateParams",
        "AuthClearParams",
        "OAuthBeginResponse",
        "ActiveCredentialParam",
        "ProviderAuthInfo",
        "ServiceAuthInfo",
        "AccountInfo",
        "ApiKeyInfo",
        "ActiveCredentialInfo",
        "AnyCodableOptional",
        "OAuthInput",
        "EngineConnection",
        "EngineTransport",
        "EngineSubscription",
    ];
    let leaks = swift_source_lines("packages/ios-app/Sources")
        .into_iter()
        .filter(|line| {
            let path = path_from_line(line);
            path.starts_with("packages/ios-app/Sources/Session/")
                || path.starts_with("packages/ios-app/Sources/UI/")
        })
        .filter(|line| {
            banned_identifiers
                .iter()
                .any(|identifier| line_has_identifier(line, identifier))
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "iOS session/UI layers must depend on repositories/view models, not concrete engine transport or raw DTOs:\n{}",
        leaks.join("\n")
    );

    let engine_client_leaks = swift_source_lines("packages/ios-app/Sources")
        .into_iter()
        .filter(|line| {
            let path = path_from_line(line);
            !path.starts_with("packages/ios-app/Sources/Engine/")
                && !path.starts_with("packages/ios-app/Sources/Support/Composition/")
        })
        .filter(|line| line_has_identifier(line, "EngineClient"))
        .collect::<Vec<_>>();

    assert!(
        engine_client_leaks.is_empty(),
        "concrete EngineClient must stay inside Engine-owned code or the composition root:\n{}",
        engine_client_leaks.join("\n")
    );
}

#[test]
fn boundary_errors_do_not_leak_impl_errors() {
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| {
            line.contains("ProviderError")
                || line.contains("rusqlite::Error")
                || line.contains("tokio_tungstenite")
                || line.contains("serde_json::Error")
        })
        .filter(|line| {
            !path_has_any_prefix(
                path_from_line(line),
                &[
                    "packages/agent/src/engine/authority/",
                    "packages/agent/src/engine/durability/",
                    "packages/agent/src/domains/model/",
                    "packages/agent/src/domains/session/event_store/",
                    "packages/agent/src/shared/observability/transport.rs",
                    "packages/agent/src/shared/server/error_mapping/mod.rs",
                    "packages/agent/src/transport/",
                ],
            )
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "implementation-detail errors must be mapped at owning boundaries:\n{}",
        leaks.join("\n")
    );
}

fn path_from_line(line: &str) -> &str {
    line.split_once(':').map_or("", |(path, _)| path)
}

fn path_has_any_prefix(path: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|prefix| path.starts_with(prefix))
}

fn line_has_identifier(line: &str, identifier: &str) -> bool {
    line.match_indices(identifier).any(|(index, _)| {
        let before = index
            .checked_sub(1)
            .and_then(|before| line.as_bytes().get(before))
            .is_none_or(|byte| !is_identifier_byte(*byte));
        let after_index = index + identifier.len();
        let after = line
            .as_bytes()
            .get(after_index)
            .is_none_or(|byte| !is_identifier_byte(*byte));
        before && after
    })
}

fn is_identifier_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn rust_source_lines(root: &str) -> Vec<String> {
    source_lines(root, "rs")
}

fn swift_source_lines(root: &str) -> Vec<String> {
    source_lines(root, "swift")
}

fn source_lines(root: &str, extension: &str) -> Vec<String> {
    let mut lines = Vec::new();
    for path in tracked_files() {
        if !path.starts_with(root)
            || Path::new(&path).extension().and_then(|e| e.to_str()) != Some(extension)
        {
            continue;
        }
        if !repo_path(&path).exists() {
            continue;
        }
        if is_test_support_path(&path) {
            continue;
        }
        let text = read_repo_file(&path);
        for (index, line) in strip_cfg_test_modules(&text).lines().enumerate() {
            let trimmed = line.trim();
            if trimmed.starts_with("//") || trimmed.starts_with("#[cfg(test)]") {
                continue;
            }
            lines.push(format!("{path}:{}:{trimmed}", index + 1));
        }
    }
    lines
}
