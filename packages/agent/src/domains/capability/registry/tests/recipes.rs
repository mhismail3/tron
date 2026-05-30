use super::support::*;

#[test]
fn agent_recipe_projects_required_payload_and_execute_template() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let entry = CapabilityRegistryEntry::from_function(function, 7);
    let recipe = entry.agent_recipe();

    assert_eq!(recipe.contract_id, "process::run");
    assert!(
        recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("command:"))
    );
    assert!(
        recipe
            .optional_payload
            .iter()
            .any(|field| field.starts_with("expectedOutputs:"))
    );
    assert_eq!(recipe.execute_template["target"], json!("process::run"));
    assert_eq!(
        recipe.execute_template["arguments"]["command"],
        json!("date")
    );
    assert_eq!(recipe.direct_execution, "conditional_safe_direct");
    assert!(!recipe.inspect_required);
    assert!(recipe.approval_behavior.contains("conditional"));
}

#[test]
fn first_party_recipes_include_every_required_payload_field() {
    let spec_sets = vec![
        crate::domains::agent::contract::capabilities().expect("agent specs"),
        crate::domains::auth::contract::capabilities().expect("auth specs"),
        crate::domains::blob::contract::capabilities().expect("blob specs"),
        crate::domains::browser::contract::capabilities().expect("browser specs"),
        crate::domains::context::contract::capabilities().expect("context specs"),
        crate::domains::cron::contract::capabilities().expect("cron specs"),
        crate::domains::device::contract::capabilities().expect("device specs"),
        crate::domains::display::contract::capabilities().expect("display specs"),
        crate::domains::events::contract::capabilities().expect("events specs"),
        crate::domains::filesystem::contract::capabilities().expect("filesystem specs"),
        crate::domains::git::contract::capabilities().expect("git specs"),
        crate::domains::import::contract::capabilities().expect("import specs"),
        crate::domains::job::contract::capabilities().expect("job specs"),
        crate::domains::logs::contract::capabilities().expect("logs specs"),
        crate::domains::mcp::contract::capabilities().expect("mcp specs"),
        crate::domains::memory::contract::capabilities().expect("memory specs"),
        crate::domains::message::contract::capabilities().expect("message specs"),
        crate::domains::model::contract::capabilities().expect("model specs"),
        crate::domains::notifications::contract::capabilities().expect("notification specs"),
        crate::domains::plan::contract::capabilities().expect("plan specs"),
        crate::domains::process::contract::capabilities().expect("process specs"),
        crate::domains::program::contract::capabilities().expect("program specs"),
        crate::domains::prompt_library::contract::capabilities().expect("prompt library specs"),
        crate::domains::repo::contract::capabilities().expect("repo specs"),
        crate::domains::sandbox::contract::capabilities().expect("sandbox specs"),
        crate::domains::session::contract::capabilities().expect("session specs"),
        crate::domains::settings::contract::capabilities().expect("settings specs"),
        crate::domains::skills::contract::capabilities().expect("skills specs"),
        crate::domains::system::contract::capabilities().expect("system specs"),
        crate::domains::transcription::contract::capabilities().expect("transcription specs"),
        crate::domains::tree::contract::capabilities().expect("tree specs"),
        crate::domains::voice_notes::contract::capabilities().expect("voice notes specs"),
        crate::domains::web::contract::capabilities().expect("web specs"),
        crate::domains::worktree::contract::capabilities().expect("worktree specs"),
    ];
    let mut checked = 0;

    for spec in spec_sets.into_iter().flatten() {
        let function = crate::domains::contract::function_definition_for_capability(&spec);
        if function.id.namespace() == "capability" {
            continue;
        }
        let Some(schema) = function.request_schema.as_ref() else {
            continue;
        };
        let Some(required) = schema.get("required").and_then(Value::as_array) else {
            continue;
        };
        let required = required
            .iter()
            .filter_map(Value::as_str)
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        if required.is_empty() {
            continue;
        }

        let entry = CapabilityRegistryEntry::from_function(function, 17);
        let recipe = entry.agent_recipe();
        for field in required {
            assert!(
                recipe
                    .required_payload
                    .iter()
                    .any(|summary| summary.starts_with(&format!("{field}:"))),
                "{} missing required payload summary for {field}",
                recipe.contract_id
            );
            assert!(
                recipe.execute_template["arguments"].get(&field).is_some(),
                "{} execute template missing required payload field {field}",
                recipe.contract_id
            );
        }
        checked += 1;
    }

    assert!(checked > 50, "expected broad first-party recipe coverage");
}

#[test]
fn first_party_recipe_parity_covers_common_direct_capabilities() {
    let specs = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .chain(crate::domains::process::contract::capabilities().expect("process specs"))
        .chain(crate::domains::notifications::contract::capabilities().expect("notification specs"))
        .collect::<Vec<_>>();

    let entries = specs
        .into_iter()
        .map(|spec| {
            CapabilityRegistryEntry::from_function(
                crate::domains::contract::function_definition_for_capability(&spec),
                17,
            )
        })
        .collect::<Vec<_>>();
    let by_contract = entries
        .iter()
        .map(|entry| (entry.contract_id.as_str(), entry.agent_recipe()))
        .collect::<BTreeMap<_, _>>();

    let process = by_contract.get("process::run").expect("process recipe");
    assert_eq!(process.execute_template["target"], json!("process::run"));
    assert!(
        process
            .required_payload
            .iter()
            .any(|field| field.starts_with("command:"))
    );
    assert!(
        process
            .optional_payload
            .iter()
            .any(|field| field.starts_with("expectedOutputs:"))
    );
    assert!(process.direct_execution.contains("conditional_safe_direct"));

    let notify = by_contract
        .get("notifications::send")
        .expect("notification recipe");
    assert_eq!(
        notify.execute_template["target"],
        json!("notifications::send")
    );
    assert!(
        notify
            .required_payload
            .iter()
            .any(|field| field.starts_with("title:"))
    );
    assert!(
        notify
            .required_payload
            .iter()
            .any(|field| field.starts_with("body:"))
    );

    let read = by_contract
        .get("filesystem::read_file")
        .expect("read file recipe");
    assert_eq!(
        read.execute_template["target"],
        json!("filesystem::read_file")
    );
    assert!(
        read.required_payload
            .iter()
            .any(|field| field.starts_with("path:"))
    );
    assert_eq!(read.approval_behavior, "none");
}

#[test]
fn filesystem_recipes_separate_new_file_creation_from_existing_patch() {
    let specs = crate::domains::filesystem::contract::capabilities().expect("filesystem specs");
    let entries = specs
        .iter()
        .map(|spec| {
            CapabilityRegistryEntry::from_function(
                crate::domains::contract::function_definition_for_capability(spec),
                17,
            )
        })
        .collect::<Vec<_>>();
    let by_contract = entries
        .iter()
        .map(|entry| (entry.contract_id.as_str(), entry.agent_recipe()))
        .collect::<BTreeMap<_, _>>();

    let write = by_contract
        .get("filesystem::write_file")
        .expect("write file recipe");
    assert!(
        write.use_when.contains("new file"),
        "write_file recipe must advertise new-file creation"
    );
    assert!(
        write.use_when.contains("scratch"),
        "write_file recipe must cover scratch/docs-sandbox file creation"
    );

    let apply_patch = by_contract
        .get("filesystem::apply_patch")
        .expect("apply patch recipe");
    assert!(
        apply_patch.use_when.contains("existing"),
        "apply_patch recipe must say it targets an existing file"
    );
    assert!(
        apply_patch.use_when.contains("filesystem::write_file"),
        "apply_patch recipe must direct new-file creation to write_file"
    );
    assert!(
        apply_patch
            .required_payload
            .iter()
            .any(|field| field.contains("existing file")),
        "apply_patch required path summary must mention an existing file"
    );

    let documents = entries
        .into_iter()
        .map(|entry| entry.search_document())
        .collect::<Vec<_>>();
    let search = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    })
    .search("create scratch docs note file", documents, 8)
    .expect("filesystem search");
    assert_eq!(
        search.hits[0].contract_id, "filesystem::write_file",
        "new scratch-file searches should prefer write_file over patch"
    );
}

#[test]
fn lexical_search_returns_recipes_for_common_first_party_queries() {
    let specs = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .chain(crate::domains::process::contract::capabilities().expect("process specs"))
        .chain(crate::domains::notifications::contract::capabilities().expect("notification specs"))
        .collect::<Vec<_>>();
    let documents = specs
        .into_iter()
        .map(|spec| {
            CapabilityRegistryEntry::from_function(
                crate::domains::contract::function_definition_for_capability(&spec),
                18,
            )
            .search_document()
        })
        .collect::<Vec<_>>();
    let index = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    });

    let process = index
        .search("process run shell command date", documents.clone(), 8)
        .expect("process search");
    let process_recipe = process
        .hits
        .iter()
        .find(|hit| hit.contract_id == "process::run")
        .and_then(|hit| hit.recipe.as_ref())
        .expect("process recipe");
    assert!(
        process
            .hits
            .iter()
            .any(|hit| hit.contract_id == "process::run" && !hit.requires_inspect)
    );
    assert!(
        process_recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("command:"))
    );
    assert_eq!(
        process_recipe.execute_template["arguments"]["command"],
        json!("date")
    );

    let notifications = index
        .search("notification notify app", documents.clone(), 8)
        .expect("notification search");
    let notification_recipe = notifications
        .hits
        .iter()
        .find(|hit| hit.contract_id == "notifications::send")
        .and_then(|hit| hit.recipe.as_ref())
        .expect("notification recipe");
    assert!(
        notification_recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("title:"))
    );
    assert!(
        notification_recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("body:"))
    );

    let read_file = index
        .search("read file", documents, 8)
        .expect("read file search");
    let read_recipe = read_file
        .hits
        .iter()
        .find(|hit| hit.contract_id == "filesystem::read_file")
        .and_then(|hit| hit.recipe.as_ref())
        .expect("read file recipe");
    assert!(
        read_recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("path:"))
    );
}

#[test]
fn approval_write_command_query_prefers_process_run_recipe() {
    let specs = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .chain(crate::domains::process::contract::capabilities().expect("process specs"))
        .collect::<Vec<_>>();
    let documents = specs
        .into_iter()
        .map(|spec| {
            CapabilityRegistryEntry::from_function(
                crate::domains::contract::function_definition_for_capability(&spec),
                19,
            )
            .search_document()
        })
        .collect::<Vec<_>>();
    let index = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    });

    let search = index
        .search(
            "high-risk write command approval pause resume",
            documents,
            8,
        )
        .expect("approval command search");
    let ranked = search
        .hits
        .iter()
        .map(|hit| format!("{}={:.2}", hit.contract_id, hit.lexical_score))
        .collect::<Vec<_>>()
        .join(", ");
    assert_eq!(
        search.hits[0].contract_id, "process::run",
        "approval-gated write command prompts should prefer process::run; ranked hits: {ranked}"
    );
    let process_recipe = search.hits[0].recipe.as_ref().expect("process recipe");
    assert!(
        process_recipe
            .examples
            .iter()
            .any(
                |example| example["arguments"]["executionMode"] == "sandbox_materialized"
                    && example["arguments"]["expectedOutputs"].is_array()
            ),
        "process recipe should include a sandbox_materialized approval-shaped example"
    );
}
