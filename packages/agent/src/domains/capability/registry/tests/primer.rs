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
fn primer_teaches_self_modifying_worker_lifecycle() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            test_function("capability::execute"),
            test_function("worker::protocol_guide"),
            test_function("worker::spawn"),
            test_function("catalog::watch_snapshot"),
            test_function("capability::inspect"),
            test_function("capability::conformance_run"),
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
        "customize the harness",
        "`worker::protocol_guide`",
        "author",
        "`worker::spawn`",
        "`catalog::watch_snapshot`",
        "`capability::inspect`",
        "conformance",
        "test",
        "`execute`",
        "`engine::promote`",
        "`worker::disconnect`",
        "`sandbox::stop_spawned_worker`",
        "trace id",
        "resource refs",
        "catalog revision",
    ] {
        assert!(
            text.contains(required),
            "self-modification primer missing lifecycle marker `{required}`:\n{text}"
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
