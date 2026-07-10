//! Canonical base-authority policy for provider-visible execute operations.
//!
//! This module owns only static policy. Runtime code resolves payload-dependent
//! values and derived resource ids described by the typed variants below. That
//! keeps engine handles, hashing, resource inspection, and business behavior
//! out of the operation contract while giving every supported operation one
//! fail-closed authority definition.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NetworkPolicy {
    None,
    Declared,
}

impl NetworkPolicy {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Declared => "declared",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConditionalAuthority {
    None,
    /// Add `resource.read` and `web.read`, plus the exact robots-policy
    /// resource, only when both proof fields are present and non-empty.
    WebRobotsProof {
        resource_id_field: &'static str,
        version_id_field: &'static str,
        additional_scopes: &'static [&'static str],
    },
    /// Add device read authority and registration custody only for an explicit
    /// push request. Delivery resolution remains runtime-owned.
    NotificationPush {
        requested_field: &'static str,
        additional_scopes: &'static [&'static str],
        additional_resource_kind: &'static str,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WorkerPackageKindSource {
    ListArgument { field: &'static str },
    InspectResourceIdPrefix { field: &'static str },
}

impl WorkerPackageKindSource {
    /// Resource kinds accepted by either worker-package resolver. Runtime code
    /// still reads the argument or id prefix and selects exactly one value.
    pub(crate) const fn allowed_resource_kinds(self) -> &'static [&'static str] {
        WORKER_PACKAGE_KINDS
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ProceduralResourceSet {
    DefinitionOrState,
    ActivationRequest,
    ActivationDecision,
}

impl ProceduralResourceSet {
    /// Kinds granted only after runtime validates the exact procedural kind.
    pub(crate) const fn resource_kinds(self) -> &'static [&'static str] {
        match self {
            Self::DefinitionOrState => PROCEDURAL_STATE_KINDS,
            Self::ActivationRequest => PROCEDURAL_REQUEST_KINDS,
            Self::ActivationDecision => PROCEDURAL_DECISION_KINDS,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CapabilityBindingResourceSet {
    Request,
    RequestAndDecision,
    Decision,
    DecisionAndPolicy,
    Policy,
    CockpitAndRouteUnion,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ModuleRuntimeResourceSet {
    RuntimeOnly,
    RuntimeAndLifecycle,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ModuleProgramExecutionResourceSet {
    Start,
    Followup,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SubagentResourceSet {
    Launch,
    Followup,
    Catalog,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ResourceKindPolicy {
    None,
    Static(&'static [&'static str]),
    OptionalGoal {
        field: &'static str,
        base_kinds: &'static [&'static str],
        linked_kind: &'static str,
    },
    WebFetchRobotsProof {
        base_kinds: &'static [&'static str],
        proof_kind: &'static str,
    },
    NotificationPush {
        base_kinds: &'static [&'static str],
        push_kind: &'static str,
    },
    Procedural {
        kind_field: &'static str,
        resources: ProceduralResourceSet,
    },
    WorkerPackage(WorkerPackageKindSource),
    CapabilityBinding(CapabilityBindingResourceSet),
    CapabilityRouteUnion,
    ModuleRuntime(ModuleRuntimeResourceSet),
    ModuleProgramExecution(ModuleProgramExecutionResourceSet),
    Subagent(SubagentResourceSet),
}

impl ResourceKindPolicy {
    /// Return all unconditional resource kinds. Dynamic variants add at most
    /// the payload-resolved kinds documented by their variant fields.
    pub(crate) const fn base_kinds(self) -> &'static [&'static str] {
        match self {
            Self::None => &[],
            Self::Static(kinds) => kinds,
            Self::OptionalGoal { base_kinds, .. }
            | Self::WebFetchRobotsProof { base_kinds, .. }
            | Self::NotificationPush { base_kinds, .. } => base_kinds,
            Self::Procedural { .. } => &[],
            Self::WorkerPackage(_) => &[],
            Self::CapabilityBinding(resources) => match resources {
                CapabilityBindingResourceSet::Request => BINDING_REQUEST_KINDS,
                CapabilityBindingResourceSet::RequestAndDecision => BINDING_REQUEST_DECISION_KINDS,
                CapabilityBindingResourceSet::Decision => BINDING_DECISION_KINDS,
                CapabilityBindingResourceSet::DecisionAndPolicy => BINDING_DECISION_POLICY_KINDS,
                CapabilityBindingResourceSet::Policy => BINDING_POLICY_KINDS,
                CapabilityBindingResourceSet::CockpitAndRouteUnion => COCKPIT_KINDS,
            },
            Self::CapabilityRouteUnion => ROUTE_KINDS,
            Self::ModuleRuntime(resources) => match resources {
                ModuleRuntimeResourceSet::RuntimeOnly => MODULE_RUNTIME_KINDS,
                ModuleRuntimeResourceSet::RuntimeAndLifecycle => MODULE_RUNTIME_LIFECYCLE_KINDS,
            },
            Self::ModuleProgramExecution(resources) => match resources {
                ModuleProgramExecutionResourceSet::Start => MODULE_PROGRAM_START_KINDS,
                ModuleProgramExecutionResourceSet::Followup => MODULE_PROGRAM_FOLLOWUP_KINDS,
            },
            Self::Subagent(resources) => match resources {
                SubagentResourceSet::Launch => SUBAGENT_LAUNCH_KINDS,
                SubagentResourceSet::Followup => SUBAGENT_FOLLOWUP_KINDS,
                SubagentResourceSet::Catalog => SUBAGENT_CATALOG_KINDS,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SelectorAddition {
    Session,
    WebRobotsProof {
        resource_id_field: &'static str,
        version_id_field: &'static str,
    },
    ProceduralKind {
        field: &'static str,
    },
    DerivedModuleLifecycleState {
        install_decision_field: &'static str,
    },
    DerivedModuleRuntimeState {
        lifecycle_field: &'static str,
        request_id_field: &'static str,
        idempotency_field: &'static str,
    },
    DerivedSubagentTask {
        task_id_field: &'static str,
    },
    DelegatedSubagentResources {
        task_resource_field: &'static str,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct AuthorityPolicy {
    capability_additions: &'static [&'static str],
    base_scope_additions: &'static [&'static str],
    conditional_authority: ConditionalAuthority,
    resource_kinds: ResourceKindPolicy,
    network_policy: NetworkPolicy,
    exact_resource_id_fields: &'static [&'static str],
    selector_additions: &'static [SelectorAddition],
}

impl AuthorityPolicy {
    pub(crate) const fn capability_additions(self) -> &'static [&'static str] {
        self.capability_additions
    }

    pub(crate) const fn base_scope_additions(self) -> &'static [&'static str] {
        self.base_scope_additions
    }

    pub(crate) const fn conditional_authority(self) -> ConditionalAuthority {
        self.conditional_authority
    }

    pub(crate) const fn resource_kind_policy(self) -> ResourceKindPolicy {
        self.resource_kinds
    }

    pub(crate) const fn network_policy(self) -> NetworkPolicy {
        self.network_policy
    }

    pub(crate) const fn exact_resource_id_fields(self) -> &'static [&'static str] {
        self.exact_resource_id_fields
    }

    pub(crate) const fn selector_additions(self) -> &'static [SelectorAddition] {
        self.selector_additions
    }
}

const EMPTY: &[&str] = &[];
const CATALOG_READ: &[&str] = &["catalog_discovery.read"];
const CATALOG_WRITE: &[&str] = &["catalog_discovery.write", "resource.write"];
const SCHEDULER_READ: &[&str] = &["scheduler.read", "resource.read"];
const SCHEDULER_WRITE: &[&str] = &["scheduler.write", "resource.read", "resource.write"];
const SCHEDULER_FIRE: &[&str] = &[
    "scheduler.fire",
    "scheduler.write",
    "resource.read",
    "resource.write",
];
const TOOL_SOURCE_READ: &[&str] = &["tool_sources.read", "resource.read"];
const STATE_READ: &[&str] = &["state.read"];
const STATE_WRITE: &[&str] = &["state.write"];
const FILESYSTEM_READ: &[&str] = &["filesystem.read", "resource.read"];
const FILESYSTEM_WRITE: &[&str] = &[
    "filesystem.read",
    "filesystem.write",
    "resource.read",
    "resource.write",
];
const GIT_READ: &[&str] = &["git.read", "resource.read"];
const GIT_WRITE: &[&str] = &["git.read", "git.write", "resource.write"];
const JOB_READ: &[&str] = &["jobs.read", "resource.read"];
const JOB_WRITE: &[&str] = &["jobs.write", "resource.write"];
const JOB_READ_WRITE: &[&str] = &["jobs.read", "jobs.write", "resource.read", "resource.write"];
const GOAL_READ: &[&str] = &["goals.read", "resource.read"];
const GOAL_WRITE: &[&str] = &["goals.write", "resource.write"];
const GOAL_READ_WRITE: &[&str] = &[
    "goals.read",
    "goals.write",
    "resource.read",
    "resource.write",
];
const CONTEXT_READ: &[&str] = &["context_control.read", "resource.read"];
const CONTEXT_WRITE: &[&str] = &[
    "context_control.read",
    "context_control.write",
    "resource.read",
    "resource.write",
];
const NOTIFICATION_READ: &[&str] = &["notifications.read", "resource.read"];
const NOTIFICATION_WRITE: &[&str] = &[
    "notifications.read",
    "notifications.write",
    "resource.read",
    "resource.write",
];
const CAPABILITY_BINDING_READ: &[&str] = &["capability_binding.read", "resource.read"];
const CAPABILITY_BINDING_WRITE: &[&str] = &[
    "capability_binding.read",
    "capability_binding.write",
    "resource.read",
    "resource.write",
];
const WEB_FETCH_BASE: &[&str] = &["resource.write", "web.write"];
const WEB_ROBOTS: &[&str] = &["resource.read", "resource.write", "web.write"];
const WEB_READ: &[&str] = &["resource.read", "web.read"];
const WEB_READ_WRITE: &[&str] = &["resource.read", "resource.write", "web.read", "web.write"];
const WEB_ROBOTS_PROOF_SCOPES: &[&str] = &["resource.read", "web.read"];
const DEVICE_PUSH_SCOPES: &[&str] = &["device.read"];
const SUBAGENT_TASK_READ: &[&str] = &["subagents.read", "resource.read"];
const SUBAGENT_FOLLOWUP_READ: &[&str] = &[
    "jobs.read",
    "module_runtime.read",
    "program_execution.read",
    "resource.read",
    "subagents.read",
];
const SUBAGENT_LAUNCH: &[&str] = &[
    "jobs.read",
    "jobs.write",
    "module_runtime.read",
    "module_runtime.write",
    "program_execution.read",
    "program_execution.write",
    "resource.read",
    "resource.write",
    "subagents.read",
    "subagents.write",
];
const SUBAGENT_CANCEL: &[&str] = &[
    "jobs.read",
    "jobs.write",
    "module_runtime.read",
    "module_runtime.write",
    "program_execution.read",
    "resource.read",
    "resource.write",
    "subagents.read",
    "subagents.write",
];

const SESSION: &[SelectorAddition] = &[SelectorAddition::Session];
const WEB_ROBOTS_SELECTOR: &[SelectorAddition] = &[SelectorAddition::WebRobotsProof {
    resource_id_field: "webRobotsPolicyResourceId",
    version_id_field: "expectedWebRobotsPolicyVersionId",
}];
const PROCEDURAL_SELECTOR: &[SelectorAddition] = &[SelectorAddition::ProceduralKind {
    field: "proceduralKind",
}];
const MODULE_LIFECYCLE_REQUEST_SELECTOR: &[SelectorAddition] =
    &[SelectorAddition::DerivedModuleLifecycleState {
        install_decision_field: "moduleInstallDecisionResourceId",
    }];
const MODULE_RUNTIME_REQUEST_SELECTOR: &[SelectorAddition] =
    &[SelectorAddition::DerivedModuleRuntimeState {
        lifecycle_field: "moduleLifecycleResourceId",
        request_id_field: "runtimeRequestId",
        idempotency_field: "idempotencyKey",
    }];
const SUBAGENT_LAUNCH_SELECTORS: &[SelectorAddition] = &[
    SelectorAddition::DerivedModuleRuntimeState {
        lifecycle_field: "moduleLifecycleResourceId",
        request_id_field: "runtimeRequestId",
        idempotency_field: "idempotencyKey",
    },
    SelectorAddition::DerivedSubagentTask {
        task_id_field: "taskId",
    },
];
const SUBAGENT_FOLLOWUP_SELECTORS: &[SelectorAddition] =
    &[SelectorAddition::DelegatedSubagentResources {
        task_resource_field: "subagentTaskResourceId",
    }];

const CONTEXT_KINDS: &[&str] = &[
    "context_control_snapshot",
    "context_control_action",
    "context_control_epoch",
    "context_survivor",
    "context_exclusion",
    "context_policy_snapshot",
];
const PROCEDURAL_STATE_KINDS: &[&str] = &["procedural_record"];
const PROCEDURAL_REQUEST_KINDS: &[&str] = &["procedural_record", "procedural_activation_request"];
const PROCEDURAL_DECISION_KINDS: &[&str] = &[
    "procedural_record",
    "procedural_activation_request",
    "procedural_activation_decision",
];
const WORKER_PACKAGE_KINDS: &[&str] = &[
    "worker_package",
    "worker_package_installation",
    "worker_package_proposal",
    "worker_package_conformance_report",
    "worker_launch_attempt",
];
const BINDING_REQUEST_KINDS: &[&str] = &["capability_binding_request"];
const BINDING_REQUEST_DECISION_KINDS: &[&str] =
    &["capability_binding_request", "capability_binding_decision"];
const BINDING_DECISION_KINDS: &[&str] = &["capability_binding_decision"];
const BINDING_DECISION_POLICY_KINDS: &[&str] =
    &["capability_binding_decision", "capability_binding_policy"];
const BINDING_POLICY_KINDS: &[&str] = &["capability_binding_policy"];
const ROUTE_KINDS: &[&str] = &[
    "capability_replacement_candidate",
    "capability_route_binding",
    "capability_route_activation",
    "capability_route_event",
    "capability_route_rollback",
    "capability_shadow_trial_evidence",
    "capability_shadow_trial_run",
    "capability_shadow_trial_decision",
    "capability_shadow_trial_request",
    "capability_binding_policy",
];
const SHADOW_KINDS: &[&str] = &[
    "capability_shadow_trial_request",
    "capability_shadow_trial_decision",
    "capability_shadow_trial_run",
    "capability_shadow_trial_evidence",
];
const COCKPIT_KINDS: &[&str] = &[
    "capability_binding_request",
    "capability_binding_decision",
    "capability_binding_policy",
    "capability_replacement_candidate",
    "capability_route_binding",
    "capability_route_activation",
    "capability_route_event",
    "capability_route_rollback",
    "capability_shadow_trial_evidence",
    "capability_shadow_trial_run",
    "capability_shadow_trial_decision",
    "capability_shadow_trial_request",
];
const MODULE_RUNTIME_KINDS: &[&str] = &["module_runtime_state"];
const MODULE_RUNTIME_LIFECYCLE_KINDS: &[&str] = &["module_runtime_state", "module_lifecycle_state"];
const MODULE_PROGRAM_START_KINDS: &[&str] = &[
    "module_runtime_state",
    "module_lifecycle_state",
    "program_execution_record",
    "job_process",
    "execution_output",
];
const MODULE_PROGRAM_FOLLOWUP_KINDS: &[&str] = &[
    "module_runtime_state",
    "program_execution_record",
    "job_process",
    "execution_output",
];
const SUBAGENT_LAUNCH_KINDS: &[&str] = &[
    "subagent_task",
    "module_runtime_state",
    "program_execution_record",
    "job_process",
    "execution_output",
    "module_lifecycle_state",
];
const SUBAGENT_FOLLOWUP_KINDS: &[&str] = &[
    "subagent_task",
    "module_runtime_state",
    "program_execution_record",
    "job_process",
    "execution_output",
];
const SUBAGENT_CATALOG_KINDS: &[&str] = &["subagent_task"];

/// Return the one canonical static authority policy for a supported operation.
///
/// Unknown names fail closed. The operation registry is intentionally not
/// consulted here, so adding a registry entry without adding its authority
/// contract is detected by the exact-coverage test rather than silently
/// receiving a default grant.
pub(crate) fn policy(operation: &str) -> Option<AuthorityPolicy> {
    let base_scope_additions = base_scope_additions(operation)?;
    let capability_additions = match operation {
        "state_get" => &["state::get"][..],
        "state_set" => &["state::set"][..],
        "state_list" => &["state::list"][..],
        _ => EMPTY,
    };
    let network_policy = match operation {
        "web_fetch" | "web_robots_check" => NetworkPolicy::Declared,
        _ => NetworkPolicy::None,
    };
    let conditional_authority = match operation {
        "web_fetch" => ConditionalAuthority::WebRobotsProof {
            resource_id_field: "webRobotsPolicyResourceId",
            version_id_field: "expectedWebRobotsPolicyVersionId",
            additional_scopes: WEB_ROBOTS_PROOF_SCOPES,
        },
        "notification_send" => ConditionalAuthority::NotificationPush {
            requested_field: "pushRequested",
            additional_scopes: DEVICE_PUSH_SCOPES,
            additional_resource_kind: "device_registration",
        },
        _ => ConditionalAuthority::None,
    };
    Some(AuthorityPolicy {
        capability_additions,
        base_scope_additions,
        conditional_authority,
        resource_kinds: resource_kind_policy(operation),
        network_policy,
        exact_resource_id_fields: exact_resource_id_fields(operation),
        selector_additions: selector_additions(operation),
    })
}

fn base_scope_additions(operation: &str) -> Option<&'static [&'static str]> {
    let scopes = match operation {
        "observe" | "process_run" | "trace_list" | "trace_get" | "log_recent"
        | "replay_manifest" => EMPTY,
        "state_get" | "state_list" => STATE_READ,
        "state_set" => STATE_WRITE,
        "filesystem_read"
        | "filesystem_list"
        | "filesystem_find"
        | "filesystem_glob"
        | "filesystem_search_text"
        | "filesystem_diff" => FILESYSTEM_READ,
        "filesystem_write" | "filesystem_edit" | "filesystem_apply_patch" => FILESYSTEM_WRITE,
        "git_status" | "git_diff" | "git_branch_inventory" => GIT_READ,
        "git_stage" | "git_unstage" | "git_commit" | "git_branch_start" => GIT_WRITE,
        "job_start" => JOB_WRITE,
        "job_status" | "job_list" | "job_log" => JOB_READ,
        "job_cancel" => JOB_READ_WRITE,
        "goal_create" => GOAL_WRITE,
        "goal_list" | "goal_inspect" | "question_list" | "question_inspect" => GOAL_READ,
        "goal_cancel" | "question_create" | "question_answer" => GOAL_READ_WRITE,
        "catalog_search" | "catalog_inspect" => CATALOG_READ,
        "catalog_conformance" => CATALOG_WRITE,
        "schedule_list" | "schedule_inspect" => SCHEDULER_READ,
        "schedule_create" | "schedule_cancel" => SCHEDULER_WRITE,
        "schedule_fire_due" => SCHEDULER_FIRE,
        "tool_source_list" | "tool_source_inspect" => TOOL_SOURCE_READ,
        "memory_status"
        | "memory_list"
        | "memory_inspect"
        | "memory_query_list"
        | "memory_query_inspect"
        | "memory_decision_list"
        | "memory_decision_inspect" => &["memory.read", "resource.read"],
        "context_control_status"
        | "context_control_action_list"
        | "context_control_action_inspect"
        | "context_survivor_list"
        | "context_exclusion_list" => CONTEXT_READ,
        "context_control_snapshot"
        | "context_control_compact"
        | "context_control_clear"
        | "context_survivor_record"
        | "context_survivor_disable"
        | "context_exclusion_record"
        | "context_exclusion_disable"
        | "context_policy_snapshot" => CONTEXT_WRITE,
        "media_list" | "media_inspect" => &["media.read", "resource.read"],
        "media_create" | "media_archive" => &[
            "media.read",
            "media.write",
            "resource.read",
            "resource.write",
        ],
        "import_history_list" | "import_history_inspect" => {
            &["import_history.read", "resource.read"]
        }
        "import_history_record" => &[
            "import_history.read",
            "import_history.write",
            "resource.read",
            "resource.write",
        ],
        "repository_tree_list" | "repository_tree_inspect" => {
            &["repository_tree.read", "resource.read"]
        }
        "repository_tree_snapshot" => &[
            "repository_tree.read",
            "repository_tree.write",
            "resource.read",
            "resource.write",
        ],
        "import_preview_list" | "import_preview_inspect" => {
            &["import_preview.read", "resource.read"]
        }
        "import_preview_record" => &[
            "import_preview.read",
            "import_preview.write",
            "resource.read",
            "resource.write",
        ],
        "program_execution_list" | "program_execution_inspect" => {
            &["program_execution.read", "resource.read"]
        }
        "program_execution_record" => &[
            "program_execution.read",
            "program_execution.write",
            "resource.read",
            "resource.write",
        ],
        "prompt_artifact_list" | "prompt_artifact_inspect" => {
            &["prompt_artifacts.read", "resource.read"]
        }
        "prompt_artifact_record" => &[
            "prompt_artifacts.read",
            "prompt_artifacts.write",
            "resource.read",
            "resource.write",
        ],
        "update_diagnostic_list" | "update_diagnostic_inspect" => {
            &["update_diagnostics.read", "resource.read"]
        }
        "update_diagnostic_record" => &[
            "update_diagnostics.read",
            "update_diagnostics.write",
            "resource.read",
            "resource.write",
        ],
        "device_list" | "device_inspect" => &["device.read", "resource.read"],
        "notification_list" | "notification_inspect" => NOTIFICATION_READ,
        "notification_send" | "notification_mark_read" | "notification_mark_all_read" => {
            NOTIFICATION_WRITE
        }
        "procedural_state_list"
        | "procedural_state_inspect"
        | "procedural_activation_request_list"
        | "procedural_activation_request_inspect"
        | "procedural_activation_decision_list"
        | "procedural_activation_decision_inspect" => &["procedural.read", "resource.read"],
        "procedural_definition_record"
        | "procedural_activation_request_record"
        | "procedural_activation_decision_record" => &[
            "procedural.read",
            "procedural.write",
            "resource.read",
            "resource.write",
        ],
        "subagent_launch" => SUBAGENT_LAUNCH,
        "subagent_status" | "subagent_result" => SUBAGENT_FOLLOWUP_READ,
        "subagent_cancel" => SUBAGENT_CANCEL,
        "subagent_task_list" | "subagent_task_inspect" => SUBAGENT_TASK_READ,
        "worker_package_list" | "worker_package_inspect" => {
            &["worker.lifecycle.read", "resource.read"]
        }
        "module_list" | "module_inspect" => &["module_registry.read", "resource.read"],
        "module_proposal_list" | "module_proposal_inspect" => {
            &["module_authoring.read", "resource.read"]
        }
        "module_proposal_record" => &[
            "module_authoring.read",
            "module_authoring.write",
            "resource.read",
            "resource.write",
        ],
        "module_validation_list" | "module_validation_inspect" => {
            &["module_validation.read", "resource.read"]
        }
        "module_validation_record" => &[
            "module_validation.read",
            "module_validation.write",
            "resource.read",
            "resource.write",
        ],
        "module_install_request_list"
        | "module_install_request_inspect"
        | "module_install_decision_list"
        | "module_install_decision_inspect" => &["module_install.read", "resource.read"],
        "module_install_request_record" | "module_install_decision_record" => &[
            "module_install.read",
            "module_install.write",
            "resource.read",
            "resource.write",
        ],
        "module_dependency_request_list"
        | "module_dependency_request_inspect"
        | "module_dependency_decision_list"
        | "module_dependency_decision_inspect"
        | "module_dependency_policy_list"
        | "module_dependency_policy_inspect" => &["module_dependencies.read", "resource.read"],
        "module_dependency_request_record"
        | "module_dependency_decision_record"
        | "module_dependency_policy_activate" => &[
            "module_dependencies.read",
            "module_dependencies.write",
            "resource.read",
            "resource.write",
        ],
        "capability_binding_request_list"
        | "capability_binding_request_inspect"
        | "capability_binding_decision_list"
        | "capability_binding_decision_inspect"
        | "capability_binding_policy_list"
        | "capability_binding_policy_inspect"
        | "capability_binding_cockpit_overview"
        | "capability_shadow_trial_evidence_inspect"
        | "capability_replacement_candidate_list"
        | "capability_replacement_candidate_inspect"
        | "capability_route_binding_list"
        | "capability_route_binding_inspect"
        | "capability_route_event_list"
        | "capability_route_event_inspect" => CAPABILITY_BINDING_READ,
        "capability_binding_request_record"
        | "capability_binding_decision_record"
        | "capability_binding_policy_activate"
        | "capability_shadow_trial_request_record"
        | "capability_shadow_trial_decision_record"
        | "capability_shadow_trial_run_record"
        | "capability_replacement_candidate_record"
        | "capability_route_binding_record"
        | "capability_route_activate"
        | "capability_route_disable"
        | "capability_route_rollback" => CAPABILITY_BINDING_WRITE,
        "module_lifecycle_list" | "module_lifecycle_inspect" => {
            &["module_lifecycle.read", "resource.read"]
        }
        "module_lifecycle_request" | "module_lifecycle_decision" => &[
            "module_lifecycle.read",
            "module_lifecycle.write",
            "resource.read",
            "resource.write",
        ],
        "module_program_execution_start" => &[
            "jobs.read",
            "jobs.write",
            "module_runtime.read",
            "module_runtime.write",
            "program_execution.read",
            "program_execution.write",
            "resource.read",
            "resource.write",
        ],
        "module_program_execution_status" => &[
            "jobs.read",
            "module_runtime.read",
            "program_execution.read",
            "resource.read",
        ],
        "module_program_execution_cancel" | "module_program_execution_cleanup" => &[
            "jobs.read",
            "jobs.write",
            "module_runtime.read",
            "module_runtime.write",
            "program_execution.read",
            "resource.read",
            "resource.write",
        ],
        "module_runtime_list" | "module_runtime_inspect" => {
            &["module_runtime.read", "resource.read"]
        }
        "module_runtime_request" | "module_runtime_cancel" => &[
            "module_runtime.read",
            "module_runtime.write",
            "resource.read",
            "resource.write",
        ],
        "web_fetch" => WEB_FETCH_BASE,
        "web_robots_check" => WEB_ROBOTS,
        "web_source_list" | "web_source_inspect" => WEB_READ,
        "web_source_archive" => WEB_READ_WRITE,
        "web_research_request_list"
        | "web_research_request_inspect"
        | "web_research_review_list"
        | "web_research_review_inspect"
        | "web_research_source_list"
        | "web_research_source_inspect" => &["web_research.read", "resource.read"],
        "web_research_request_record"
        | "web_research_review_record"
        | "web_research_source_record" => &[
            "web_research.read",
            "web_research.write",
            "resource.read",
            "resource.write",
        ],
        _ => return None,
    };
    Some(scopes)
}

fn resource_kind_policy(operation: &str) -> ResourceKindPolicy {
    match operation {
        "catalog_conformance" => ResourceKindPolicy::Static(&["catalog_discovery_report"]),
        "trace_list" | "trace_get" => ResourceKindPolicy::Static(&["trace_record"]),
        "log_recent" => ResourceKindPolicy::Static(&["log_entry"]),
        "replay_manifest" => ResourceKindPolicy::Static(&["session"]),
        "schedule_create" | "schedule_list" | "schedule_inspect" | "schedule_cancel"
        | "schedule_fire_due" => ResourceKindPolicy::Static(&["schedule", "schedule_run"]),
        "tool_source_list" => ResourceKindPolicy::Static(&["tool_source_proposal"]),
        "tool_source_inspect" => {
            ResourceKindPolicy::Static(&["tool_source_proposal", "tool_source_conformance_report"])
        }
        "goal_create" | "goal_list" | "goal_inspect" | "goal_cancel" => {
            ResourceKindPolicy::Static(&["goal"])
        }
        "question_create" => ResourceKindPolicy::OptionalGoal {
            field: "goalResourceId",
            base_kinds: &["user_question"],
            linked_kind: "goal",
        },
        "question_list" | "question_inspect" => ResourceKindPolicy::Static(&["user_question"]),
        "question_answer" => ResourceKindPolicy::Static(&["user_question", "goal_answer"]),
        "memory_status" => ResourceKindPolicy::Static(&["memory_policy", "memory_engine"]),
        "memory_list" | "memory_inspect" => ResourceKindPolicy::Static(&["memory_record"]),
        "memory_query_list" | "memory_query_inspect" => {
            ResourceKindPolicy::Static(&["memory_query"])
        }
        "memory_decision_list" | "memory_decision_inspect" => {
            ResourceKindPolicy::Static(&["memory_decision"])
        }
        "context_control_status"
        | "context_control_snapshot"
        | "context_control_compact"
        | "context_control_clear"
        | "context_control_action_list"
        | "context_control_action_inspect"
        | "context_survivor_record"
        | "context_survivor_list"
        | "context_survivor_disable"
        | "context_exclusion_record"
        | "context_exclusion_list"
        | "context_exclusion_disable"
        | "context_policy_snapshot" => ResourceKindPolicy::Static(CONTEXT_KINDS),
        "media_create" | "media_list" | "media_inspect" | "media_archive" => {
            ResourceKindPolicy::Static(&["media_artifact"])
        }
        "import_history_record" | "import_history_list" | "import_history_inspect" => {
            ResourceKindPolicy::Static(&["import_history_record"])
        }
        "repository_tree_snapshot" | "repository_tree_list" | "repository_tree_inspect" => {
            ResourceKindPolicy::Static(&["repository_tree_snapshot"])
        }
        "import_preview_record" | "import_preview_list" | "import_preview_inspect" => {
            ResourceKindPolicy::Static(&["import_preview"])
        }
        "program_execution_record" | "program_execution_list" | "program_execution_inspect" => {
            ResourceKindPolicy::Static(&["program_execution_record"])
        }
        "prompt_artifact_record" | "prompt_artifact_list" | "prompt_artifact_inspect" => {
            ResourceKindPolicy::Static(&["prompt_artifact"])
        }
        "update_diagnostic_record" | "update_diagnostic_list" | "update_diagnostic_inspect" => {
            ResourceKindPolicy::Static(&["update_diagnostic_record"])
        }
        "device_list" | "device_inspect" => ResourceKindPolicy::Static(&["device_registration"]),
        "notification_list" => ResourceKindPolicy::Static(&["notification"]),
        "notification_inspect" => {
            ResourceKindPolicy::Static(&["notification", "notification_delivery"])
        }
        "notification_send" => ResourceKindPolicy::NotificationPush {
            base_kinds: &["notification", "notification_delivery"],
            push_kind: "device_registration",
        },
        "notification_mark_read" | "notification_mark_all_read" => {
            ResourceKindPolicy::Static(&["notification", "notification_delivery"])
        }
        "procedural_definition_record" | "procedural_state_list" | "procedural_state_inspect" => {
            ResourceKindPolicy::Procedural {
                kind_field: "proceduralKind",
                resources: ProceduralResourceSet::DefinitionOrState,
            }
        }
        "procedural_activation_request_record"
        | "procedural_activation_request_list"
        | "procedural_activation_request_inspect" => ResourceKindPolicy::Procedural {
            kind_field: "proceduralKind",
            resources: ProceduralResourceSet::ActivationRequest,
        },
        "procedural_activation_decision_record"
        | "procedural_activation_decision_list"
        | "procedural_activation_decision_inspect" => ResourceKindPolicy::Procedural {
            kind_field: "proceduralKind",
            resources: ProceduralResourceSet::ActivationDecision,
        },
        "subagent_launch" => ResourceKindPolicy::Subagent(SubagentResourceSet::Launch),
        "subagent_status" | "subagent_result" | "subagent_cancel" => {
            ResourceKindPolicy::Subagent(SubagentResourceSet::Followup)
        }
        "subagent_task_list" | "subagent_task_inspect" => {
            ResourceKindPolicy::Subagent(SubagentResourceSet::Catalog)
        }
        "worker_package_list" => {
            ResourceKindPolicy::WorkerPackage(WorkerPackageKindSource::ListArgument {
                field: "workerPackageKind",
            })
        }
        "worker_package_inspect" => {
            ResourceKindPolicy::WorkerPackage(WorkerPackageKindSource::InspectResourceIdPrefix {
                field: "workerPackageResourceId",
            })
        }
        "module_list" | "module_inspect" => ResourceKindPolicy::Static(&["module_manifest"]),
        "module_proposal_record" | "module_proposal_list" | "module_proposal_inspect" => {
            ResourceKindPolicy::Static(&["module_proposal"])
        }
        "module_validation_record" | "module_validation_list" | "module_validation_inspect" => {
            ResourceKindPolicy::Static(&["module_validation_report"])
        }
        "module_install_request_record"
        | "module_install_request_list"
        | "module_install_request_inspect"
        | "module_install_decision_record"
        | "module_install_decision_list"
        | "module_install_decision_inspect" => {
            ResourceKindPolicy::Static(&["module_install_request", "module_install_decision"])
        }
        "module_dependency_request_record"
        | "module_dependency_request_list"
        | "module_dependency_request_inspect"
        | "module_dependency_decision_record"
        | "module_dependency_decision_list"
        | "module_dependency_decision_inspect"
        | "module_dependency_policy_activate"
        | "module_dependency_policy_list"
        | "module_dependency_policy_inspect" => ResourceKindPolicy::Static(&[
            "module_dependency_request",
            "module_dependency_decision",
            "module_dependency_policy",
        ]),
        "capability_binding_request_record"
        | "capability_binding_request_list"
        | "capability_binding_request_inspect" => {
            ResourceKindPolicy::CapabilityBinding(CapabilityBindingResourceSet::Request)
        }
        "capability_binding_decision_record" => {
            ResourceKindPolicy::CapabilityBinding(CapabilityBindingResourceSet::RequestAndDecision)
        }
        "capability_binding_decision_list" | "capability_binding_decision_inspect" => {
            ResourceKindPolicy::CapabilityBinding(CapabilityBindingResourceSet::Decision)
        }
        "capability_binding_policy_activate" => {
            ResourceKindPolicy::CapabilityBinding(CapabilityBindingResourceSet::DecisionAndPolicy)
        }
        "capability_binding_policy_list" | "capability_binding_policy_inspect" => {
            ResourceKindPolicy::CapabilityBinding(CapabilityBindingResourceSet::Policy)
        }
        "capability_binding_cockpit_overview" => ResourceKindPolicy::CapabilityBinding(
            CapabilityBindingResourceSet::CockpitAndRouteUnion,
        ),
        "capability_shadow_trial_request_record"
        | "capability_shadow_trial_decision_record"
        | "capability_shadow_trial_run_record"
        | "capability_shadow_trial_evidence_inspect" => ResourceKindPolicy::Static(SHADOW_KINDS),
        "capability_replacement_candidate_record"
        | "capability_replacement_candidate_list"
        | "capability_replacement_candidate_inspect"
        | "capability_route_binding_record"
        | "capability_route_binding_list"
        | "capability_route_binding_inspect"
        | "capability_route_activate"
        | "capability_route_disable"
        | "capability_route_rollback"
        | "capability_route_event_list"
        | "capability_route_event_inspect" => ResourceKindPolicy::CapabilityRouteUnion,
        "module_lifecycle_request"
        | "module_lifecycle_decision"
        | "module_lifecycle_list"
        | "module_lifecycle_inspect" => ResourceKindPolicy::Static(&["module_lifecycle_state"]),
        "module_runtime_request" => {
            ResourceKindPolicy::ModuleRuntime(ModuleRuntimeResourceSet::RuntimeAndLifecycle)
        }
        "module_runtime_list" | "module_runtime_inspect" | "module_runtime_cancel" => {
            ResourceKindPolicy::ModuleRuntime(ModuleRuntimeResourceSet::RuntimeOnly)
        }
        "module_program_execution_start" => {
            ResourceKindPolicy::ModuleProgramExecution(ModuleProgramExecutionResourceSet::Start)
        }
        "module_program_execution_status"
        | "module_program_execution_cancel"
        | "module_program_execution_cleanup" => {
            ResourceKindPolicy::ModuleProgramExecution(ModuleProgramExecutionResourceSet::Followup)
        }
        "job_start" | "job_status" | "job_list" | "job_log" | "job_cancel" => {
            ResourceKindPolicy::Static(&["job_process", "execution_output"])
        }
        "filesystem_read"
        | "filesystem_list"
        | "filesystem_find"
        | "filesystem_glob"
        | "filesystem_search_text"
        | "filesystem_diff" => ResourceKindPolicy::Static(&["materialized_file"]),
        "filesystem_write" | "filesystem_edit" | "filesystem_apply_patch" => {
            ResourceKindPolicy::Static(&["patch_proposal", "materialized_file"])
        }
        "git_status" | "git_diff" | "git_branch_inventory" => {
            ResourceKindPolicy::Static(&["git_index_change", "git_commit", "git_branch_start"])
        }
        "git_stage" | "git_unstage" => ResourceKindPolicy::Static(&["git_index_change"]),
        "git_commit" => ResourceKindPolicy::Static(&["git_commit"]),
        "git_branch_start" => ResourceKindPolicy::Static(&["git_branch_start"]),
        "web_robots_check" => ResourceKindPolicy::Static(&["web_robots_policy"]),
        "web_fetch" => ResourceKindPolicy::WebFetchRobotsProof {
            base_kinds: &["web_source"],
            proof_kind: "web_robots_policy",
        },
        "web_source_list" | "web_source_inspect" | "web_source_archive" => {
            ResourceKindPolicy::Static(&["web_source"])
        }
        "web_research_request_record"
        | "web_research_request_list"
        | "web_research_request_inspect"
        | "web_research_review_record"
        | "web_research_review_list"
        | "web_research_review_inspect"
        | "web_research_source_record"
        | "web_research_source_list"
        | "web_research_source_inspect" => ResourceKindPolicy::Static(&[
            "web_research_request",
            "web_research_review",
            "web_research_source",
        ]),
        _ => ResourceKindPolicy::None,
    }
}

fn exact_resource_id_fields(operation: &str) -> &'static [&'static str] {
    match operation {
        "goal_inspect" | "goal_cancel" | "question_create" => &["goalResourceId"],
        "question_inspect" | "question_answer" => &["questionResourceId"],
        "media_inspect" | "media_archive" => &["mediaResourceId"],
        "import_history_inspect" => &["importHistoryResourceId"],
        "repository_tree_inspect" => &["repositoryTreeResourceId"],
        "import_preview_inspect" => &["importPreviewResourceId"],
        "program_execution_inspect" => &["programExecutionResourceId"],
        "prompt_artifact_inspect" => &["promptArtifactResourceId"],
        "update_diagnostic_inspect" => &["updateDiagnosticResourceId"],
        "memory_inspect" => &["recordResourceId"],
        "memory_query_inspect" => &["queryResourceId"],
        "memory_decision_inspect" => &["decisionResourceId"],
        "context_control_action_inspect" => &["contextControlActionResourceId"],
        "context_survivor_disable" => &["contextSurvivorResourceId"],
        "context_exclusion_disable" => &["contextExclusionResourceId"],
        "module_inspect" => &["moduleManifestResourceId"],
        "module_proposal_inspect" => &["moduleProposalResourceId"],
        "module_validation_inspect" | "module_install_request_record" => {
            &["moduleValidationReportResourceId"]
        }
        "module_install_request_inspect" | "module_install_decision_record" => {
            &["moduleInstallRequestResourceId"]
        }
        "module_install_decision_inspect" | "module_lifecycle_request" => {
            &["moduleInstallDecisionResourceId"]
        }
        "module_dependency_request_inspect" | "module_dependency_decision_record" => {
            &["moduleDependencyRequestResourceId"]
        }
        "module_dependency_decision_inspect" | "module_dependency_policy_activate" => {
            &["moduleDependencyDecisionResourceId"]
        }
        "module_dependency_policy_inspect" => &["moduleDependencyPolicyResourceId"],
        "capability_binding_request_inspect" | "capability_binding_decision_record" => {
            &["capabilityBindingRequestResourceId"]
        }
        "capability_binding_decision_inspect" | "capability_binding_policy_activate" => {
            &["capabilityBindingDecisionResourceId"]
        }
        "capability_binding_policy_inspect" => &["capabilityBindingPolicyResourceId"],
        "capability_replacement_candidate_inspect" | "capability_route_binding_record" => {
            &["capabilityReplacementCandidateResourceId"]
        }
        "capability_route_binding_inspect" | "capability_route_activate" => {
            &["capabilityRouteBindingResourceId"]
        }
        "capability_route_disable" | "capability_route_rollback" => &[
            "capabilityRouteBindingResourceId",
            "capabilityRouteActivationResourceId",
        ],
        "capability_route_event_inspect" => &["capabilityRouteEventResourceId"],
        "web_research_request_inspect" | "web_research_review_record" => {
            &["webResearchRequestResourceId"]
        }
        "web_research_source_record" => &[
            "webResearchRequestResourceId",
            "webResearchReviewResourceId",
        ],
        "web_research_review_inspect" => &["webResearchReviewResourceId"],
        "web_research_source_inspect" => &["webResearchSourceResourceId"],
        "module_lifecycle_decision" | "module_lifecycle_inspect" => &["moduleLifecycleResourceId"],
        "module_runtime_request" | "module_program_execution_start" | "subagent_launch" => {
            &["moduleLifecycleResourceId"]
        }
        "module_runtime_inspect" | "module_runtime_cancel" => &["moduleRuntimeResourceId"],
        "module_program_execution_status"
        | "module_program_execution_cancel"
        | "module_program_execution_cleanup" => &["moduleRuntimeResourceId", "jobResourceId"],
        "subagent_status" | "subagent_result" | "subagent_cancel" => &["subagentTaskResourceId"],
        "procedural_state_inspect" | "procedural_activation_request_record" => {
            &["proceduralRecordResourceId"]
        }
        "procedural_activation_request_inspect" | "procedural_activation_decision_record" => {
            &["proceduralActivationRequestResourceId"]
        }
        "procedural_activation_decision_inspect" => &["proceduralActivationDecisionResourceId"],
        _ => EMPTY,
    }
}

fn selector_additions(operation: &str) -> &'static [SelectorAddition] {
    match operation {
        "context_control_status"
        | "context_control_snapshot"
        | "context_control_compact"
        | "context_control_clear"
        | "context_control_action_list"
        | "context_control_action_inspect"
        | "context_survivor_record"
        | "context_survivor_list"
        | "context_survivor_disable"
        | "context_exclusion_record"
        | "context_exclusion_list"
        | "context_exclusion_disable"
        | "context_policy_snapshot"
        | "capability_binding_cockpit_overview"
        | "capability_replacement_candidate_record"
        | "capability_replacement_candidate_list"
        | "capability_replacement_candidate_inspect"
        | "capability_route_binding_record"
        | "capability_route_binding_list"
        | "capability_route_binding_inspect"
        | "capability_route_activate"
        | "capability_route_disable"
        | "capability_route_rollback"
        | "capability_route_event_list"
        | "capability_route_event_inspect" => SESSION,
        "web_fetch" => WEB_ROBOTS_SELECTOR,
        "procedural_definition_record"
        | "procedural_state_list"
        | "procedural_state_inspect"
        | "procedural_activation_request_record"
        | "procedural_activation_request_list"
        | "procedural_activation_request_inspect"
        | "procedural_activation_decision_record"
        | "procedural_activation_decision_list"
        | "procedural_activation_decision_inspect" => PROCEDURAL_SELECTOR,
        "module_lifecycle_request" => MODULE_LIFECYCLE_REQUEST_SELECTOR,
        "module_runtime_request" | "module_program_execution_start" => {
            MODULE_RUNTIME_REQUEST_SELECTOR
        }
        "subagent_launch" => SUBAGENT_LAUNCH_SELECTORS,
        "subagent_status" | "subagent_result" | "subagent_cancel" => SUBAGENT_FOLLOWUP_SELECTORS,
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::super::OperationId;
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn every_supported_operation_has_exactly_one_policy_and_unknowns_fail_closed() {
        assert_eq!(OperationId::ALL_NAMES.len(), 188);
        let unique = OperationId::ALL_NAMES
            .iter()
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(unique.len(), OperationId::ALL_NAMES.len());
        for operation in OperationId::ALL_NAMES {
            assert!(
                policy(operation).is_some(),
                "missing authority policy for {operation}"
            );
        }
        for unknown in ["", "git", "state_read", "capability_route_*", "unknown"] {
            assert!(
                policy(unknown).is_none(),
                "unknown operation {unknown} must fail closed"
            );
        }
    }

    #[test]
    fn policies_are_explicit_local_and_never_restore_agent_state_or_wildcards() {
        for operation in OperationId::ALL_NAMES {
            let policy = policy(operation).expect("covered operation");
            assert!(matches!(
                policy.network_policy(),
                NetworkPolicy::None | NetworkPolicy::Declared
            ));
            for value in policy
                .capability_additions()
                .iter()
                .chain(policy.base_scope_additions())
                .chain(policy.exact_resource_id_fields())
            {
                assert!(
                    !value.contains('*'),
                    "{operation} contains wildcard policy value {value}"
                );
                assert!(
                    !value.contains("agent_state"),
                    "{operation} restores forbidden agent_state authority"
                );
            }
            for kind in policy.resource_kind_policy().base_kinds() {
                assert!(!kind.contains('*'));
                assert_ne!(*kind, "agent_state");
            }
        }
    }

    #[test]
    fn empty_authority_and_resource_policies_are_intentional_exact_sets() {
        let empty_scope_operations = [
            "observe",
            "process_run",
            "trace_list",
            "trace_get",
            "log_recent",
            "replay_manifest",
        ]
        .into_iter()
        .collect::<BTreeSet<_>>();
        let no_resource_operations = [
            "observe",
            "state_get",
            "state_set",
            "state_list",
            "process_run",
            "catalog_search",
            "catalog_inspect",
        ]
        .into_iter()
        .collect::<BTreeSet<_>>();

        for operation in OperationId::ALL_NAMES {
            let policy = policy(operation).expect("covered operation");
            assert_eq!(
                policy.base_scope_additions().is_empty(),
                empty_scope_operations.contains(operation),
                "unexpected empty/non-empty base scopes for {operation}"
            );
            assert_eq!(
                policy.resource_kind_policy() == ResourceKindPolicy::None,
                no_resource_operations.contains(operation),
                "unexpected absent/present resource policy for {operation}"
            );
        }
    }

    #[test]
    fn network_authority_is_declared_only_for_live_web_operations() {
        let declared = OperationId::ALL_NAMES
            .iter()
            .copied()
            .filter(|operation| {
                policy(operation)
                    .expect("covered operation")
                    .network_policy()
                    == NetworkPolicy::Declared
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(declared, BTreeSet::from(["web_fetch", "web_robots_check"]));
    }

    #[test]
    fn state_authority_uses_exact_capabilities_without_resource_inheritance() {
        let get = policy("state_get").expect("state get");
        assert_eq!(get.capability_additions(), &["state::get"]);
        assert_eq!(get.base_scope_additions(), &["state.read"]);
        assert_eq!(get.resource_kind_policy(), ResourceKindPolicy::None);
        assert_eq!(get.network_policy().as_str(), "none");

        let set = policy("state_set").expect("state set");
        assert_eq!(set.capability_additions(), &["state::set"]);
        assert_eq!(set.base_scope_additions(), &["state.write"]);
    }

    #[test]
    fn dynamic_cases_are_typed_and_leave_values_to_runtime_resolution() {
        let web = policy("web_fetch").expect("web fetch");
        assert_eq!(web.network_policy(), NetworkPolicy::Declared);
        assert!(matches!(
            web.conditional_authority(),
            ConditionalAuthority::WebRobotsProof {
                resource_id_field: "webRobotsPolicyResourceId",
                version_id_field: "expectedWebRobotsPolicyVersionId",
                ..
            }
        ));
        assert!(matches!(
            web.resource_kind_policy(),
            ResourceKindPolicy::WebFetchRobotsProof { .. }
        ));

        let push = policy("notification_send").expect("notification send");
        assert!(matches!(
            push.conditional_authority(),
            ConditionalAuthority::NotificationPush {
                requested_field: "pushRequested",
                ..
            }
        ));
        let worker = policy("worker_package_inspect")
            .expect("worker package inspect")
            .resource_kind_policy();
        let ResourceKindPolicy::WorkerPackage(worker_source) = worker else {
            panic!("worker-package kind source must remain dynamic");
        };
        assert!(matches!(
            worker_source,
            WorkerPackageKindSource::InspectResourceIdPrefix { .. }
        ));
        assert_eq!(worker_source.allowed_resource_kinds(), WORKER_PACKAGE_KINDS);

        let procedural = policy("procedural_activation_decision_record")
            .expect("procedural decision")
            .resource_kind_policy();
        let ResourceKindPolicy::Procedural { resources, .. } = procedural else {
            panic!("procedural resource policy must remain kind-gated");
        };
        assert_eq!(resources, ProceduralResourceSet::ActivationDecision);
        assert_eq!(resources.resource_kinds(), PROCEDURAL_DECISION_KINDS);
        assert!(procedural.base_kinds().is_empty());
    }

    #[test]
    fn governance_unions_and_runtime_linkages_are_explicit() {
        let cockpit = policy("capability_binding_cockpit_overview").expect("cockpit");
        assert_eq!(
            cockpit.resource_kind_policy(),
            ResourceKindPolicy::CapabilityBinding(
                CapabilityBindingResourceSet::CockpitAndRouteUnion
            )
        );
        assert_eq!(cockpit.selector_additions(), SESSION);

        let route = policy("capability_route_activate").expect("route activation");
        assert_eq!(
            route.resource_kind_policy(),
            ResourceKindPolicy::CapabilityRouteUnion
        );
        assert_eq!(
            route.exact_resource_id_fields(),
            &["capabilityRouteBindingResourceId"]
        );

        let runtime = policy("module_runtime_request").expect("runtime request");
        assert_eq!(
            runtime.resource_kind_policy(),
            ResourceKindPolicy::ModuleRuntime(ModuleRuntimeResourceSet::RuntimeAndLifecycle)
        );
        assert_eq!(
            runtime.selector_additions(),
            MODULE_RUNTIME_REQUEST_SELECTOR
        );

        let launch = policy("subagent_launch").expect("subagent launch");
        assert_eq!(
            launch.resource_kind_policy(),
            ResourceKindPolicy::Subagent(SubagentResourceSet::Launch)
        );
        assert_eq!(launch.selector_additions(), SUBAGENT_LAUNCH_SELECTORS);
    }

    #[test]
    fn exact_resource_fields_are_operation_specific() {
        assert_eq!(
            policy("capability_route_rollback")
                .expect("route rollback")
                .exact_resource_id_fields(),
            &[
                "capabilityRouteBindingResourceId",
                "capabilityRouteActivationResourceId"
            ]
        );
        assert_eq!(
            policy("web_research_source_record")
                .expect("research source")
                .exact_resource_id_fields(),
            &[
                "webResearchRequestResourceId",
                "webResearchReviewResourceId"
            ]
        );
        assert!(
            policy("catalog_search")
                .expect("catalog search")
                .exact_resource_id_fields()
                .is_empty()
        );
    }
}
