use super::support::*;

#[test]
fn engine_catalog_and_durability_roots_are_split_and_explicit() {
    for (path, limit) in [
        ("packages/agent/src/engine/catalog/registry/mod.rs", 750),
        (
            "packages/agent/src/engine/catalog/registry/invocation.rs",
            750,
        ),
        ("packages/agent/src/engine/durability/ledger/mod.rs", 750),
        ("packages/agent/src/engine/durability/queue/mod.rs", 750),
        ("packages/agent/src/engine/durability/streams/mod.rs", 750),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-2 engine file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/agent/src/engine/catalog/registry/registration.rs",
        "packages/agent/src/engine/catalog/registry/idempotency.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_store.rs",
        "packages/agent/src/engine/durability/queue/memory.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/streams/memory.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-2 expected split owner missing: {path}"
        );
    }

    let ledger = read_repo_file("packages/agent/src/engine/durability/ledger/mod.rs");
    for banned in [
        "fn upsert_durable_worker_definition(&mut self, _definition: &WorkerDefinition)",
        "fn remove_durable_worker_definition(&mut self, _worker_id: &WorkerId)",
        "fn list_durable_worker_definitions(&self) -> Result<Vec<WorkerDefinition>> {\n        Ok(Vec::new())",
        "fn upsert_durable_function_definition(\n        &mut self,\n        _definition: &FunctionDefinition",
        "fn remove_durable_function_definition(&mut self, _function_id: &FunctionId)",
        "fn list_durable_function_definitions(&self) -> Result<Vec<FunctionDefinition>> {\n        Ok(Vec::new())",
    ] {
        assert!(
            !ledger.contains(banned),
            "EngineLedgerStore must not retain default no-op durable catalog method `{banned}`"
        );
    }
}
