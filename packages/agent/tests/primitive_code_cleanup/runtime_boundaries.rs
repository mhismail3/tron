use super::support::*;

#[test]
fn small_rust_domains_stay_collapsed_to_single_worker_modules() {
    for path in [
        "packages/agent/src/domains/blob/contract.rs",
        "packages/agent/src/domains/blob/deps.rs",
        "packages/agent/src/domains/blob/handlers.rs",
        "packages/agent/src/domains/logs/contract.rs",
        "packages/agent/src/domains/logs/deps.rs",
        "packages/agent/src/domains/logs/handlers.rs",
        "packages/agent/src/domains/message/contract.rs",
        "packages/agent/src/domains/message/deps.rs",
        "packages/agent/src/domains/message/handlers.rs",
        "packages/agent/src/domains/system/contract.rs",
        "packages/agent/src/domains/system/deps.rs",
        "packages/agent/src/domains/system/handlers.rs",
    ] {
        assert!(
            !repo_path(path).exists(),
            "small Rust domain boilerplate shard must stay collapsed: {path}"
        );
    }

    for path in [
        "packages/agent/src/domains/blob/mod.rs",
        "packages/agent/src/domains/logs/mod.rs",
        "packages/agent/src/domains/message/mod.rs",
        "packages/agent/src/domains/system/mod.rs",
    ] {
        let source = read_repo_file(path);
        for required in [
            "pub(crate) fn capabilities()",
            "pub(crate) struct Deps",
            "operation_bindings!",
            "function_registrations(capabilities()?, domain_deps)?",
        ] {
            assert!(
                source.contains(required),
                "collapsed small domain {path} missing `{required}`"
            );
        }
    }

    let domain_catalog = read_repo_file("packages/agent/src/domains/registration/catalog.rs");
    for required in [
        "super::blob::capabilities()?",
        "super::logs::capabilities()?",
        "super::message::capabilities()?",
        "super::system::capabilities()?",
    ] {
        assert!(
            domain_catalog.contains(required),
            "domain catalog must use collapsed small-domain owner `{required}`"
        );
    }
}

#[test]
fn engine_primitive_surface_stays_in_owned_boundaries() {
    for path in [
        "packages/agent/src/engine/durability/resources/store/events.rs",
        "packages/agent/src/engine/durability/resources/store/trace_events.rs",
        "packages/agent/src/domains/capability/deps.rs",
        "packages/agent/src/domains/capability/handlers.rs",
    ] {
        assert!(
            !repo_path(path).exists(),
            "unowned engine substrate shard must stay collapsed or deleted: {path}"
        );
    }

    let engine_type_mod = read_repo_file("packages/agent/src/engine/kernel/types/mod.rs");
    let catalog_types = read_repo_file("packages/agent/src/engine/kernel/types/catalog.rs");
    for required in [
        "pub enum CatalogSubjectKind",
        "pub enum CatalogChangeClass",
        "pub struct CatalogChange",
        "pub enum CatalogChangeKind",
    ] {
        assert!(
            catalog_types.contains(required),
            "engine catalog type shard missing retained catalog type `{required}`"
        );
    }
    for required in ["mod catalog;", "pub use catalog::{"] {
        assert!(
            engine_type_mod.contains(required),
            "engine type aggregator missing explicit catalog boundary `{required}`"
        );
    }

    let resource_store =
        read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    for required in ["fn resource_event(", "fn generated_id("] {
        assert!(
            resource_store.contains(required),
            "resource store missing collapsed event helper `{required}`"
        );
    }
    for banned in ["mod events;", "mod trace_events;", "events_by_trace("] {
        assert!(
            !resource_store.contains(banned),
            "resource store must not retain unproven event shard/API `{banned}`"
        );
    }

    let engine_tests = read_repo_file("packages/agent/src/engine/tests/mod.rs");
    for banned in ["fn ", "#[test]", "async fn "] {
        assert!(
            !engine_tests.contains(banned),
            "engine/tests/mod.rs must stay declaration-only and fixture-only"
        );
    }
    assert!(
        engine_tests.contains("mod fixtures;")
            && engine_tests.contains("mod authority;")
            && engine_tests.contains("mod catalog;")
            && engine_tests.contains("mod durability;")
            && engine_tests.contains("mod invocation;")
            && engine_tests.contains("mod kernel;")
            && engine_tests.contains("mod runtime;"),
        "engine tests must stay organized by substrate concern"
    );

    let capability_mod = read_repo_file("packages/agent/src/domains/capability/mod.rs");
    for required in [
        "pub(crate) struct Deps",
        "function_registrations(contract::capabilities()?, domain_deps)?",
        "struct ExecuteHandler",
        "execute_value(&invocation, &self.deps)",
    ] {
        assert!(
            capability_mod.contains(required),
            "capability execute worker missing collapsed local owner `{required}`"
        );
    }
    for banned in [
        "mod deps;",
        "mod handlers;",
        "pub(crate) use deps::Deps;",
        "handlers::function_registrations",
        "operation_bindings!",
    ] {
        assert!(
            !capability_mod.contains(banned),
            "capability execute worker must not recreate boilerplate shard `{banned}`"
        );
    }

    let capability_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    assert!(
        capability_contract
            .contains("pub(crate) const EXECUTE_FUNCTION_ID: &str = \"capability::execute\";")
            && capability_contract.contains("fn only_execute_is_registered_and_model_facing()"),
        "capability contract must retain the single execute primitive proof"
    );
}

#[test]
fn session_persistence_surface_stays_current_and_collapsed() {
    for path in [
        "packages/agent/src/domains/session/deps.rs",
        "packages/agent/src/domains/session/handlers.rs",
        "packages/agent/src/domains/session/operations.rs",
        "packages/agent/src/domains/session/operations/mod.rs",
        "packages/agent/src/domains/session/operations/lifecycle.rs",
    ] {
        assert!(
            !repo_path(path).exists(),
            "session helper shard must stay collapsed into its owner: {path}"
        );
    }
    for path in [
        "packages/agent/src/domains/session/lifecycle/operations.rs",
        "packages/agent/src/domains/session/query/operations.rs",
        "packages/agent/src/domains/session/reconstruction/operations.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "session operation wrapper must live beside its owner: {path}"
        );
    }

    let session_mod = read_repo_file("packages/agent/src/domains/session/mod.rs");
    for required in [
        "pub(crate) struct Deps",
        "operation_bindings!",
        "function_registrations(contract::capabilities()?, domain_deps)?",
        "\"create\" => |invocation, deps|",
        "\"export\" => |invocation, deps|",
    ] {
        assert!(
            session_mod.contains(required),
            "collapsed session worker missing `{required}`"
        );
    }
    for banned in [
        "pub(crate) mod deps;",
        "pub(crate) mod handlers;",
        "pub(crate) use deps::Deps;",
        "handlers::function_registrations",
        "operations/",
        concat!("dash", "board query"),
    ] {
        assert!(
            !session_mod.contains(banned),
            "session worker must not retain stale helper/doc text `{banned}`"
        );
    }

    let lifecycle_ops =
        read_repo_file("packages/agent/src/domains/session/lifecycle/operations.rs");
    let query_ops = read_repo_file("packages/agent/src/domains/session/query/operations.rs");
    let reconstruction_ops =
        read_repo_file("packages/agent/src/domains/session/reconstruction/operations.rs");
    for (source, required, label) in [
        (
            lifecycle_ops.as_str(),
            "SessionLifecycleService",
            "lifecycle operations",
        ),
        (
            query_ops.as_str(),
            "SessionQueryService",
            "query operations",
        ),
        (
            reconstruction_ops.as_str(),
            "SessionReconstructionService",
            "reconstruction operations",
        ),
    ] {
        assert!(
            source.contains(required),
            "{label} must route to the owning session service `{required}`"
        );
    }

    let sqlite_docs =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/mod.rs");
    for banned in [
        "Constitution",
        "constitution",
        "v002_constitution_audit",
        "settings/instruction/context/provider",
        "follow-up migrations",
    ] {
        assert!(
            !sqlite_docs.contains(banned),
            "SQLite event-store docs must describe only current primitive storage, found `{banned}`"
        );
    }

    let message_ops = read_repo_file(
        "packages/agent/src/domains/session/event_store/types/payloads/message_ops.rs",
    );
    for banned in [
        concat!("Message", "Queued", "Payload"),
        concat!("Message", "Dequeued", "Payload"),
        concat!("message", ".", "queued"),
        concat!("message", ".", "dequeued"),
    ] {
        assert!(
            !message_ops.contains(banned),
            "retired message queue payload DTO must stay absent: `{banned}`"
        );
    }

    let schema = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for banned in [
        "constitution",
        "push_token",
        "device_token",
        "cron",
        "session_profile",
        "worktree",
        "prompt_queue",
        "config_mutation",
        "rules",
        "skills",
        "hooks",
        "capability_registry",
        "policy_profile",
    ] {
        assert!(
            !schema.contains(banned),
            "fresh primitive schema must not recreate old product table/column text `{banned}`"
        );
    }
}

#[test]
fn prompt_queue_and_shell_list_residue_stays_out_of_retained_runtime_source() {
    let banned_terms = [
        concat!("apply", "_", "enqueued"),
        concat!("send", "-", "to", "-", "queue"),
        concat!("queue", " drain mode"),
        concat!("queued", " follow-up"),
        concat!("hidden prompt apply starts ", "queued"),
        concat!("queued", " runtime work"),
        concat!("Dash", "board"),
        concat!("dash", "board"),
        concat!("Message", "Queue"),
        concat!("Queued", "Message"),
        concat!("queue", "Prompt"),
        concat!("clear", "Queue"),
        concat!("dequeue", "Prompt"),
        concat!("queue", "Drain", "Mode"),
        concat!("message", "Queue"),
        concat!("Queued", "Message", "Chips"),
        concat!("Message", "Queued"),
        concat!("Message", "Dequeued"),
        concat!("queued", "_", "message"),
        concat!("message", ".", "queued"),
        concat!("message", ".", "dequeued"),
    ];

    for path in git_ls_files() {
        if !(path.starts_with("packages/agent/src/")
            || path.starts_with("packages/ios-app/Sources/")
            || path.starts_with("packages/ios-app/Tests/"))
        {
            continue;
        }
        if !matches!(
            Path::new(&path)
                .extension()
                .and_then(|extension| extension.to_str()),
            Some("md" | "rs" | "swift")
        ) {
            continue;
        }
        let text = read_repo_file(&path);
        for term in banned_terms {
            assert!(
                !text.contains(term),
                "retired prompt queue/session-list term `{term}` must stay out of retained source {path}"
            );
        }
    }
}
