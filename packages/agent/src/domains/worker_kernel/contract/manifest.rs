//! Stable identity, grouping, and ordering for every model-facing primitive.

/// Stable model-facing primitive families.
///
/// This is deliberately narrower than the complete worker-kernel contract:
/// internal webhook and inbox projection functions are kernel mechanics, not
/// model vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum CorePrimitiveGroup {
    Host,
    WorkerControl,
    CoreChange,
}

impl CorePrimitiveGroup {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::WorkerControl => "worker_control",
            Self::CoreChange => "core_change",
        }
    }
}

/// One canonical model-facing primitive identity.
///
/// Contracts, handlers, provider projection, dashboard projection, and tests
/// derive full function identity and ordering from this manifest instead of
/// storing function-name fragments or maintaining parallel name maps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CorePrimitiveDescriptor {
    pub(crate) function_id: &'static str,
    pub(crate) model_name: &'static str,
    pub(crate) group: CorePrimitiveGroup,
    pub(crate) order: u16,
}

const CORE_PRIMITIVES: &[CorePrimitiveDescriptor] = &[
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::filesystem_read",
        model_name: "filesystem_read",
        group: CorePrimitiveGroup::Host,
        order: 10,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::filesystem_list",
        model_name: "filesystem_list",
        group: CorePrimitiveGroup::Host,
        order: 20,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::filesystem_search_text",
        model_name: "filesystem_search_text",
        group: CorePrimitiveGroup::Host,
        order: 30,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::filesystem_write",
        model_name: "filesystem_write",
        group: CorePrimitiveGroup::Host,
        order: 40,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::filesystem_edit",
        model_name: "filesystem_edit",
        group: CorePrimitiveGroup::Host,
        order: 45,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::process_run",
        model_name: "process_run",
        group: CorePrimitiveGroup::Host,
        order: 50,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::web_fetch",
        model_name: "web_fetch",
        group: CorePrimitiveGroup::Host,
        order: 60,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::session_set_title",
        model_name: "session_set_title",
        group: CorePrimitiveGroup::Host,
        order: 70,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::upsert",
        model_name: "worker_upsert",
        group: CorePrimitiveGroup::WorkerControl,
        order: 100,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::discover",
        model_name: "worker_discover",
        group: CorePrimitiveGroup::WorkerControl,
        order: 110,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::list",
        model_name: "worker_list",
        group: CorePrimitiveGroup::WorkerControl,
        order: 120,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::inspect",
        model_name: "worker_inspect",
        group: CorePrimitiveGroup::WorkerControl,
        order: 130,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::invoke",
        model_name: "worker_invoke",
        group: CorePrimitiveGroup::WorkerControl,
        order: 140,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::await",
        model_name: "worker_await",
        group: CorePrimitiveGroup::WorkerControl,
        order: 145,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::stop",
        model_name: "worker_stop",
        group: CorePrimitiveGroup::WorkerControl,
        order: 150,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::disable",
        model_name: "worker_disable",
        group: CorePrimitiveGroup::WorkerControl,
        order: 160,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::enable",
        model_name: "worker_enable",
        group: CorePrimitiveGroup::WorkerControl,
        order: 170,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::rollback",
        model_name: "worker_rollback",
        group: CorePrimitiveGroup::WorkerControl,
        order: 180,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::retire",
        model_name: "worker_retire",
        group: CorePrimitiveGroup::WorkerControl,
        order: 190,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::purge",
        model_name: "worker_purge",
        group: CorePrimitiveGroup::WorkerControl,
        order: 200,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::inbox",
        model_name: "worker_inbox",
        group: CorePrimitiveGroup::WorkerControl,
        order: 210,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::runs",
        model_name: "worker_runs",
        group: CorePrimitiveGroup::WorkerControl,
        order: 220,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::webhook_rotate",
        model_name: "worker_webhook_rotate",
        group: CorePrimitiveGroup::WorkerControl,
        order: 230,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::stop_all",
        model_name: "worker_stop_all",
        group: CorePrimitiveGroup::WorkerControl,
        order: 240,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::core_proposal_create",
        model_name: "core_proposal_create",
        group: CorePrimitiveGroup::CoreChange,
        order: 300,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::core_proposal_list",
        model_name: "core_proposal_list",
        group: CorePrimitiveGroup::CoreChange,
        order: 310,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::core_proposal_inspect",
        model_name: "core_proposal_inspect",
        group: CorePrimitiveGroup::CoreChange,
        order: 320,
    },
    CorePrimitiveDescriptor {
        function_id: "worker_kernel::core_proposal_apply",
        model_name: "core_proposal_apply",
        group: CorePrimitiveGroup::CoreChange,
        order: 330,
    },
];

pub(crate) const fn core_primitives() -> &'static [CorePrimitiveDescriptor] {
    CORE_PRIMITIVES
}

pub(crate) fn core_primitive_for_function(
    function_id: &str,
) -> Option<&'static CorePrimitiveDescriptor> {
    core_primitives()
        .iter()
        .find(|descriptor| descriptor.function_id == function_id)
}
