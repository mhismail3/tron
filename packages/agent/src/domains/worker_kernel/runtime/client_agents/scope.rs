//! Authenticated session relationship scope and complete canonical directories.

use super::*;

impl WorkerRuntime {
    pub(super) async fn client_agent_scope(
        &self,
        invocation: &Invocation,
    ) -> Result<ClientAgentScope, String> {
        if invocation.causal_context.actor_kind != ActorKind::Client {
            return Err("agent management projections require an authenticated client".to_owned());
        }
        let owner_session_id = required_client_string(&invocation.payload, "ownerSessionId")?;
        if invocation.causal_context.session_id.as_deref() != Some(owner_session_id.as_str()) {
            return Err(
                "agent management ownerSessionId does not match client provenance".to_owned(),
            );
        }
        let (owner, _) = self.resolve_calling_agent(invocation).await?;
        let agents = self.complete_agent_directory()?;
        let mut related_ids = agents
            .values()
            .filter(|agent| agent.root_session_id == owner.root_session_id)
            .map(|agent| agent.agent_id.clone())
            .collect::<HashSet<_>>();
        let team_ids = related_ids.iter().cloned().collect::<Vec<_>>();
        for agent_id in team_ids {
            for correspondent in self.all_agent_correspondents(&agent_id)? {
                if agents.contains_key(&correspondent.agent_id) {
                    related_ids.insert(correspondent.agent_id);
                }
            }
        }
        related_ids.insert(owner.agent_id.clone());
        Ok(ClientAgentScope {
            owner,
            agents,
            related_ids,
        })
    }

    pub(super) fn complete_agent_directory(
        &self,
    ) -> Result<HashMap<String, AgentInstanceRecord>, String> {
        let mut offset = 0_usize;
        let mut agents = HashMap::new();
        loop {
            let page = self
                .store
                .agent_instance_directory_page(true, &[], "", offset, 200)?;
            let page_len = page.items.len();
            for agent in page.items {
                agents.insert(agent.agent_id.clone(), agent);
            }
            offset = offset.saturating_add(page_len);
            if page_len == 0 || u64::try_from(offset).unwrap_or(u64::MAX) >= page.total {
                break;
            }
        }
        Ok(agents)
    }

    pub(super) fn all_agent_correspondents(
        &self,
        agent_id: &str,
    ) -> Result<Vec<crate::domains::session::event_store::AgentCorrespondentRecord>, String> {
        let mut offset = 0_usize;
        let mut correspondents = Vec::new();
        loop {
            let page = self
                .event_store
                .agent_correspondent_page(agent_id, &[], offset, 200)
                .map_err(|error| error.to_string())?;
            let page_len = page.items.len();
            correspondents.extend(page.items);
            offset = offset.saturating_add(page_len);
            if page_len == 0 || u64::try_from(offset).unwrap_or(u64::MAX) >= page.total {
                break;
            }
        }
        Ok(correspondents)
    }

    pub(super) fn require_scoped_agent<'a>(
        &self,
        scope: &'a ClientAgentScope,
        agent_id: &str,
    ) -> Result<&'a AgentInstanceRecord, String> {
        if !scope.related_ids.contains(agent_id) {
            return Err(format!(
                "agent '{agent_id}' is outside the selected session relationship graph"
            ));
        }
        scope
            .agents
            .get(agent_id)
            .ok_or_else(|| format!("agent '{agent_id}' was not found"))
    }
}
