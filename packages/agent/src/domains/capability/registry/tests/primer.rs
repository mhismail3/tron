use super::support::*;

#[test]
fn primer_respects_core_policy() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            test_function("filesystem::read_file"),
            test_function("memory::retain"),
        ],
        1,
    );
    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 200,
            ..Default::default()
        },
    )
    .expect("primer");
    assert!(text.contains("filesystem::read_file"));
    assert!(!text.contains("memory::retain"));
}

#[test]
fn primer_marks_process_run_safe_direct_path() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let process = crate::domains::contract::function_definition_for_capability(&process_spec);
    let entry = CapabilityRegistryEntry::from_function(process.clone(), 1);
    let recipe = entry.agent_recipe();
    assert!(recipe.examples.iter().any(|example| {
        example["target"] == json!("process::run")
            && example["arguments"]["executionMode"] == json!("read_only")
    }));
    assert!(recipe.examples.iter().any(|example| {
        example["target"] == json!("process::run")
            && example["arguments"]["executionMode"] == json!("sandbox_materialized")
            && example["arguments"]["expectedOutputs"].is_array()
    }));

    let snapshot = CapabilityRegistrySnapshot::new(vec![process], 1);

    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 600,
            include_compact_schemas: true,
            ..Default::default()
        },
    )
    .expect("primer");

    assert!(text.contains("process::run"));
    assert!(text.contains("conditional; payloads classified as risky"));
    assert!(text.contains("\"target\":\"process::run\""));
    assert!(!text.contains("\"capabilityId\""));
    assert!(!text.contains("inspectRevision=1"));
}

#[test]
fn primer_guides_approval_gated_write_commands_to_process_run() {
    let specs = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .chain(crate::domains::process::contract::capabilities().expect("process specs"))
        .filter(|spec| {
            matches!(
                spec.function_id.as_str(),
                "filesystem::write_file" | "process::run"
            )
        })
        .map(|spec| crate::domains::contract::function_definition_for_capability(&spec))
        .collect::<Vec<_>>();
    let snapshot = CapabilityRegistrySnapshot::new(specs, 19);
    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 1400,
            include_compact_schemas: true,
            include_examples: true,
            ..Default::default()
        },
    )
    .expect("primer");

    assert!(text.contains("do not target approval::request directly"));
    assert!(text.contains("Approval-gated write commands use process::run"));
    assert!(text.contains("not filesystem::write_file"));
    assert!(text.contains("\"executionMode\":\"sandbox_materialized\""));
    assert!(text.contains("\"expectedOutputs\""));
    assert!(text.contains("Each path must be relative"));
    assert!(
        text.contains("Use when: Create a new file or overwrite an existing file"),
        "write_file must keep its scratch-file recipe while the primer header disambiguates approval workflows"
    );
}

#[test]
fn primer_uses_worker_first_orchestration_language() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            test_function("capability::execute"),
            test_function("agent::spawn_subagent"),
            test_function("agent::subagent_status"),
            test_function("agent::subagent_result"),
            test_function("self_extension::grant_workspace_autonomy"),
            test_function("worker::protocol_guide"),
            test_function("worker::spawn"),
        ],
        42,
    );
    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 1700,
            include_compact_schemas: true,
            include_examples: false,
            ..Default::default()
        },
    )
    .expect("worker guide");

    assert!(text.starts_with("# Worker Guide\n\n"), "{text}");
    for required in [
        "Work router",
        "worker abilities",
        "For non-trivial work",
        "delegate focused investigation, implementation, or verification slices to workers",
        "`agent::spawn_subagent`",
        "spawn fan-out workers before collecting results",
        "Report Work status, outcomes, blockers, and cleanup state in chat",
        "Keep grant ids, trace ids, resource refs, catalog revision, child invocation ids, function ids, and raw schemas in Audit",
    ] {
        assert!(
            text.contains(required),
            "worker-first guide missing marker `{required}`:\n{text}"
        );
    }
    for forbidden in [
        "# Capability Primer",
        "customize the harness",
        "Report trace id",
    ] {
        assert!(
            !text.contains(forbidden),
            "worker-first guide must not expose stale wording `{forbidden}`:\n{text}"
        );
    }
}

#[test]
fn primer_teaches_self_modifying_worker_lifecycle() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            test_function("capability::execute"),
            test_function("self_extension::grant_workspace_autonomy"),
            test_function("worker::protocol_guide"),
            test_function("worker::spawn"),
            test_function("catalog::watch_snapshot"),
            test_function("capability::inspect"),
            test_function("capability::conformance_run"),
            test_function("ui::surface_for_target"),
            test_function("ui::inspect_surface"),
            test_function("ui::submit_action"),
            test_function("worker::disconnect"),
        ],
        42,
    );
    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 1700,
            include_compact_schemas: true,
            include_examples: false,
            ..Default::default()
        },
    )
    .expect("primer");

    for required in [
        "extend autonomous Work",
        "`self_extension::grant_workspace_autonomy`",
        "omit workspaceId for the current workspace",
        "Workspace-visible helper work",
        "`workspaceAutonomyGrantId`",
        "returned workspaceId",
        "resourceSelectors is omitted",
        "`workspace:<workspaceId>`",
        "execute's top-level workspaceId",
        "`Safe in this workspace`",
        "`worker::protocol_guide`",
        "author",
        "`worker::spawn`",
        "`catalog::watch_snapshot`",
        "`capability::inspect`",
        "conformance",
        "test",
        "`execute`",
        "generated `ui_surface`",
        "`ui::surface_for_target`",
        "`ui::inspect_surface`",
        "`ui::submit_action`",
        "stored surface/version/action ids",
        "`engine::promote`",
        "sandbox-spawned helpers",
        "`worker::disconnect`",
        "`sandbox::stop_spawned_worker`",
        "`worktree::discard_files`",
        "repository-relative paths only",
        "Report Work status, outcomes, blockers, and cleanup state in chat",
        "Keep grant ids, trace ids, resource refs, catalog revision, child invocation ids, function ids, and raw schemas in Audit",
    ] {
        assert!(
            text.contains(required),
            "self-modification primer missing lifecycle marker `{required}`:\n{text}"
        );
    }
    assert!(
        !text.contains("Report trace id"),
        "self-modification primer must not instruct normal chat to expose raw evidence ids:\n{text}"
    );
}

#[test]
fn capability_primer_context_stays_within_budget() {
    let profile_budget =
        crate::shared::profile::CapabilityContextPrimerPolicySpec::default().max_tokens;
    let mut functions = vec![
        test_function("capability::execute"),
        test_function("self_extension::grant_workspace_autonomy"),
        test_function("worker::protocol_guide"),
        test_function("worker::spawn"),
        test_function("catalog::watch_snapshot"),
        test_function("capability::inspect"),
        test_function("capability::conformance_run"),
        test_function("module::register_package"),
        test_function("module::activate"),
        test_function("module::run_conformance"),
        test_function("ui::surface_for_target"),
        test_function("ui::inspect_surface"),
        test_function("ui::submit_action"),
        test_function("worker::disconnect"),
    ];
    for index in 0..80 {
        functions.push(verbose_core_function(index));
    }
    let snapshot = CapabilityRegistrySnapshot::new(functions, 314);
    let policy = CapabilityContextPrimerPolicy {
        max_tokens: profile_budget,
        include_compact_schemas: true,
        include_examples: true,
        ..Default::default()
    };
    let text = render_capability_primer(&snapshot, &policy).expect("primer");
    let estimated_tokens = text.len() / 4;

    assert!(
        estimated_tokens <= profile_budget,
        "primer estimate {estimated_tokens} exceeded profile budget {profile_budget}:\n{text}"
    );
    assert!(
        text.contains("Catalog revision: 314."),
        "primer snapshot must identify the live catalog revision:\n{text}"
    );
    assert!(
        text.contains(
            "Additional worker abilities are available through the same `execute` Work router"
        ),
        "noisy core snapshot should truncate entries with execute guidance instead of expanding the catalog:\n{text}"
    );
    for required in [
        "`self_extension::grant_workspace_autonomy`",
        "omit workspaceId for the current workspace",
        "`workspaceAutonomyGrantId`",
        "returned workspaceId",
        "resourceSelectors is omitted",
        "`workspace:<workspaceId>`",
        "execute's top-level workspaceId",
        "`Safe in this workspace`",
        "`worker::protocol_guide`",
        "`worker::spawn`",
        "`catalog::watch_snapshot`",
        "`capability::inspect`",
        "conformance or test evidence",
        "`module::register_package`",
        "worker_package",
        "`module::activate`",
        "`module::run_conformance`",
        "source trust",
        "generated `ui_surface`",
        "`ui::surface_for_target`",
        "`ui::inspect_surface`",
        "`ui::submit_action`",
        "stored surface/version/action ids",
        "`engine::promote`",
        "sandbox-spawned helpers",
        "`worker::disconnect`",
        "`sandbox::stop_spawned_worker`",
        "`worktree::discard_files`",
        "repository-relative paths only",
        "Report Work status, outcomes, blockers, and cleanup state in chat",
        "Keep grant ids, trace ids, resource refs, catalog revision, child invocation ids, function ids, and raw schemas in Audit",
        "cleanup state",
    ] {
        assert!(
            text.contains(required),
            "bounded primer missing core recipe marker `{required}`:\n{text}"
        );
    }
}

#[test]
fn notification_send_is_core_searchable_and_primed() {
    let notification_spec = crate::domains::notifications::contract::capabilities()
        .expect("notification specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "notifications::send")
        .expect("notifications::send spec");
    let function = crate::domains::contract::function_definition_for_capability(&notification_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 12);
    assert_eq!(entry.context_primer_level, "core");
    assert!(entry.function.tags.iter().any(|tag| tag == "push"));

    let docs = vec![entry.search_document()];
    let result = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    })
    .search("send test notification push", docs, 10)
    .expect("search");
    assert_eq!(result.hits[0].contract_id, "notifications::send");

    let snapshot = CapabilityRegistrySnapshot::new(vec![function], 12);
    let text = render_capability_primer(
        &snapshot,
        &CapabilityContextPrimerPolicy {
            max_tokens: 700,
            include_compact_schemas: true,
            include_examples: true,
            ..Default::default()
        },
    )
    .expect("primer");
    assert!(text.contains("notifications::send"));
    assert!(text.contains("\"target\":\"notifications::send\""));
    assert!(!text.contains("\"capabilityId\""));
    assert!(!text.contains("inspectRevision=1"));
}

fn verbose_core_function(index: usize) -> FunctionDefinition {
    let mut function = test_function(&format!("noise_{index}::inspect"));
    function.description = format!(
        "Verbose primer budget fixture {index} with enough wording to force compact truncation before the rendered catalog becomes a prompt-expanded tool list"
    );
    function.request_schema = Some(json!({
        "type": "object",
        "required": [
            "resourceId",
            "expectedRevision",
            "includeDiagnostics",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedRevision": {"type": "integer"},
            "includeDiagnostics": {"type": "boolean"},
            "reason": {"type": "string"}
        }
    }));
    function.metadata = json!({
        "contextPrimerLevel": "core",
        "trustTier": "first_party_signed",
        "examples": [{
            "target": function.id.as_str(),
            "arguments": {
                "resourceId": format!("resource-{index}"),
                "expectedRevision": index,
                "includeDiagnostics": true,
                "reason": "budget fixture"
            }
        }]
    });
    function
}
