//! Actor-visible function discovery.

use crate::engine::catalog::discovery::ActorContext;
use crate::engine::kernel::policy;
use crate::engine::kernel::types::FunctionDefinition;

use super::LiveCatalog;

impl LiveCatalog {
    /// Return every function visible to one concrete actor.
    #[must_use]
    pub fn visible_functions(&self, actor: &ActorContext) -> Vec<FunctionDefinition> {
        self.functions
            .values()
            .filter(|entry| policy::is_visible_to_actor(&entry.definition, actor))
            .map(|entry| entry.definition.clone())
            .collect()
    }
}
