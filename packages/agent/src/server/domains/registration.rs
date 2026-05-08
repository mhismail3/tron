//! Domain worker registration.
//!
//! This module registers canonical in-process domain workers, their functions,
//! hidden apply functions, tool functions, and trigger definitions. Transport
//! startup calls this module once; individual domain workers own the executable
//! behavior and metadata.
//!
//! Domain workers such as `skills`, `filesystem`, `events`, `notifications`, `plan`, `settings`,
//! `logs`, `prompt_library`, `model`, `session`, `context`, `job`, `agent`,
//! `git`, `worktree`, `auth`, `device`, `voice_notes`, `transcription`,
//! `browser`, `display`, `sandbox`, `mcp`, and `system` own executable
//! function contracts and behavior metadata. A separate `tool` worker registers
//! built-in agent tools as
//! canonical `tool::*` functions. Provider requests now resolve schemas from
//! the live catalog, so built-ins, engine meta-tools, and eligible MCP
//! capabilities are all surfaced through the same agent-facing capability
//! fabric instead of through a frozen `ToolRegistry` snapshot.
//! `engine_ws` trigger records capture public engine protocol messages.
//! `cron_schedule` trigger records capture scheduled automation fires.
//!
//! # INVARIANT: canonical capabilities are the executable surface
//!
//! Domain method names are internal operation keys for service routing only.
//! Only canonical function ids are registered.

use crate::engine::Result as EngineResult;
use crate::server::shared::context::ServerCapabilityContext;

use crate::server::domains::catalog;

/// Register server-owned domain workers, canonical functions, and trigger records.
pub fn register_domain_workers_for_context(ctx: &ServerCapabilityContext) -> EngineResult<()> {
    register_domain_workers(ctx)?;
    crate::server::domains::tools::register_builtin_tools_for_context(ctx)?;
    Ok(())
}

fn register_domain_workers(ctx: &ServerCapabilityContext) -> EngineResult<()> {
    let handle = &ctx.engine_host;
    for module in crate::server::domains::all_worker_modules(ctx)? {
        let _stream_topics = module.stream_topics;
        handle.register_worker_for_setup(module.worker, false)?;
        for function in module.functions {
            handle.register_function_for_setup(
                function.definition,
                Some(function.handler),
                false,
            )?;
        }
    }
    handle.register_trigger_type_for_setup(catalog::cron_schedule_trigger_type()?, false)?;
    let deps = crate::server::domains::EngineCapabilityDeps::from_context(ctx);
    let cron_deps = crate::server::domains::cron::Deps::from_engine(&deps);
    crate::server::domains::cron::project_all_cron_triggers_for_setup(handle, &cron_deps)?;
    Ok(())
}
