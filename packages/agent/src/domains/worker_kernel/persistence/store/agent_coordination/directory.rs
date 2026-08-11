//! Agent, assignment, topology, relationship, and resource directory reads.
//!
//! All pages remain SQL-owned and count-backed.

use super::*;

impl WorkerStore {
    pub(crate) fn agent_instance(
        &self,
        agent_id: &str,
    ) -> Result<Option<AgentInstanceRecord>, String> {
        let connection = self.connection()?;
        query_agent(&connection, agent_id)
    }

    pub(crate) fn agent_instance_for_session(
        &self,
        session_id: &str,
    ) -> Result<Option<AgentInstanceRecord>, String> {
        let connection = self.connection()?;
        query_agent_by_session(&connection, session_id)
    }

    pub(crate) fn agent_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<Option<AgentAssignmentRecord>, String> {
        let connection = self.connection()?;
        query_assignment(&connection, assignment_id)
    }

    pub(crate) fn agent_result(
        &self,
        result_id: &str,
    ) -> Result<Option<AgentResultRecord>, String> {
        let connection = self.connection()?;
        agent_result_record(&connection, result_id)
    }

    pub(crate) fn resolve_agent_result(&self, result_id: &str) -> Result<Option<Value>, String> {
        let connection = self.connection()?;
        resolve_agent_result_in_tx(&connection, result_id)
    }

    pub(crate) fn execution_node(
        &self,
        execution_id: &str,
    ) -> Result<Option<ExecutionNodeRecord>, String> {
        let connection = self.connection()?;
        query_execution(&connection, execution_id)
    }

    pub(crate) fn execution_node_for_worker_invocation(
        &self,
        invocation_id: &str,
    ) -> Result<Option<ExecutionNodeRecord>, String> {
        validate_runtime_identifier(invocation_id, "worker invocation id", 256)?;
        let connection = self.connection()?;
        let execution_id = connection
            .query_row(
                "SELECT execution_id FROM execution_nodes WHERE worker_invocation_id=?1",
                [invocation_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("load worker execution identity: {error}"))?;
        execution_id
            .map(|execution_id| query_execution(&connection, &execution_id))
            .transpose()
            .map(Option::flatten)
    }

    /// Return the exact immutable causal path from its root to one execution.
    ///
    /// Coordination wait admission resolves this path before crossing into the
    /// EventStore, which cannot join `workers.sqlite` while it owns a Tron
    /// transaction. Iterative parent reads share one connection, reject a
    /// corrupt loop, and retain the execution graph's hard 64-node ceiling as
    /// a fail-closed traversal bound.
    pub(crate) fn execution_ancestry(
        &self,
        execution_id: &str,
    ) -> Result<Vec<ExecutionNodeRecord>, String> {
        validate_runtime_identifier(execution_id, "execution id", 512)?;
        let connection = self.connection()?;
        let mut current = Some(execution_id.to_owned());
        let mut seen = std::collections::BTreeSet::new();
        let mut ancestry = Vec::new();
        while let Some(candidate) = current {
            if !seen.insert(candidate.clone()) {
                return Err(format!(
                    "mixed execution topology contains a cycle at '{candidate}'"
                ));
            }
            if ancestry.len() >= 64 {
                return Err("mixed execution ancestry exceeds the 64-node graph ceiling".to_owned());
            }
            let node = query_execution(&connection, &candidate)?
                .ok_or_else(|| format!("execution '{candidate}' was not found"))?;
            current = node.parent_execution_id.clone();
            ancestry.push(node);
        }
        ancestry.reverse();
        Ok(ancestry)
    }

    /// Persist an autonomy stop for one exact causal graph. Repeating the
    /// same stop is idempotent and preserves the first pause evidence until an
    /// authenticated operator resumes the trace.
    #[cfg(test)]
    pub(crate) fn pause_coordination_trace(
        &self,
        trace_id: &str,
        reason: &str,
    ) -> Result<CoordinationTraceStateRecord, String> {
        self.pause_coordination_trace_with_root(trace_id, None, reason)
    }

    /// Persist a pause even before a root-only coordination trace has admitted
    /// its first execution node. The caller supplies engine-derived ownership;
    /// any durable execution topology must agree exactly.
    pub(crate) fn pause_coordination_trace_for_root(
        &self,
        trace_id: &str,
        root_session_id: &str,
        reason: &str,
    ) -> Result<CoordinationTraceStateRecord, String> {
        validate_runtime_identifier(root_session_id, "coordination root session id", 256)?;
        self.pause_coordination_trace_with_root(trace_id, Some(root_session_id), reason)
    }

    fn pause_coordination_trace_with_root(
        &self,
        trace_id: &str,
        requested_root_session_id: Option<&str>,
        reason: &str,
    ) -> Result<CoordinationTraceStateRecord, String> {
        validate_runtime_identifier(trace_id, "coordination trace id", 256)?;
        let reason = reason.trim();
        if reason.is_empty() || reason.as_bytes().len() > MAX_ERROR_BYTES {
            return Err(format!(
                "coordination pause reason must contain 1..={MAX_ERROR_BYTES} UTF-8 bytes"
            ));
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start coordination trace pause: {error}"))?;
        let (root_count, root_session_id) = transaction
            .query_row(
                "SELECT COUNT(DISTINCT root_session_id),MIN(root_session_id)
                 FROM execution_nodes
                 WHERE trace_id=?1 AND root_session_id IS NOT NULL",
                [trace_id],
                |row| Ok((row.get::<_, u32>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .map_err(|error| format!("resolve coordination trace owner: {error}"))?;
        if root_count == 0 && requested_root_session_id.is_none() {
            return Err(format!("coordination trace '{trace_id}' was not found"));
        }
        if root_count > 1 {
            return Err(format!(
                "coordination trace '{trace_id}' has ambiguous root-session ownership"
            ));
        }
        let topology_root_session_id = root_session_id;
        if let (Some(requested), Some(topology)) = (
            requested_root_session_id,
            topology_root_session_id.as_deref(),
        ) && requested != topology
        {
            return Err("coordination trace pause ownership conflict".to_owned());
        }
        let root_session_id = requested_root_session_id
            .map(ToOwned::to_owned)
            .or(topology_root_session_id)
            .ok_or_else(|| format!("coordination trace '{trace_id}' has no root session"))?;
        let owns_root = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM agent_instances
                    WHERE root_session_id=?1 OR session_id=?1
                 )",
                [&root_session_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("validate coordination trace owner: {error}"))?;
        if !owns_root {
            return Err(format!(
                "coordination root session '{root_session_id}' has no stable agent identity"
            ));
        }
        if let Some(existing) = query_coordination_trace_state(&transaction, trace_id)? {
            if existing.root_session_id != root_session_id {
                return Err("coordination trace pause ownership conflict".to_owned());
            }
            if existing.paused {
                transaction
                    .commit()
                    .map_err(|error| format!("commit idempotent coordination pause: {error}"))?;
                return Ok(existing);
            }
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "INSERT INTO coordination_trace_states(
                    trace_id,root_session_id,state,reason,created_at,updated_at,paused_at,resumed_at
                 ) VALUES (?1,?2,'paused',?3,?4,?4,?4,NULL)
                 ON CONFLICT(trace_id) DO UPDATE SET
                    state='paused',reason=excluded.reason,updated_at=excluded.updated_at,
                    paused_at=excluded.paused_at,resumed_at=NULL",
                params![trace_id, root_session_id, reason, now],
            )
            .map_err(|error| format!("persist coordination trace pause: {error}"))?;
        let record = query_coordination_trace_state(&transaction, trace_id)?
            .ok_or_else(|| "paused coordination trace state disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit coordination trace pause: {error}"))?;
        Ok(record)
    }

    /// Resume one paused graph. Missing and already-active traces are stable
    /// no-ops, making authenticated operator retries safe across reconnects.
    pub(crate) fn resume_coordination_trace(&self, trace_id: &str) -> Result<bool, String> {
        validate_runtime_identifier(trace_id, "coordination trace id", 256)?;
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE coordination_trace_states
                 SET state='active',updated_at=?2,resumed_at=?2
                 WHERE trace_id=?1 AND state='paused'",
                params![trace_id, now],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("resume coordination trace: {error}"))
    }

    pub(crate) fn coordination_trace_state(
        &self,
        trace_id: &str,
    ) -> Result<Option<CoordinationTraceStateRecord>, String> {
        validate_runtime_identifier(trace_id, "coordination trace id", 256)?;
        let connection = self.connection()?;
        query_coordination_trace_state(&connection, trace_id)
    }

    pub(crate) fn coordination_trace_is_paused(&self, trace_id: &str) -> Result<bool, String> {
        Ok(self
            .coordination_trace_state(trace_id)?
            .is_some_and(|state| state.paused))
    }

    /// Stable name/id ordered profile directory page with SQL-owned filtering
    /// and an exact total. Callers can continue through the full profile
    /// without loading the whole directory first.
    pub(crate) fn agent_instance_directory_page(
        &self,
        include_closed: bool,
        statuses: &[String],
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<AgentInstancePage, String> {
        for status in statuses {
            if AgentInstanceState::parse(status).is_none() {
                return Err(format!("unknown agent directory status '{status}'"));
            }
        }
        if query.len() > 512 {
            return Err("agent directory query exceeds 512 bytes".to_owned());
        }
        let statuses_json = serde_json::to_string(statuses)
            .map_err(|error| format!("encode agent directory statuses: {error}"))?;
        let pattern = sqlite_contains_pattern(query);
        let connection = self.connection()?;
        let where_clause = "(?1=1 OR state!='closed')
             AND (json_array_length(?2)=0 OR state IN (SELECT value FROM json_each(?2)))
             AND (?3='' OR lower(name) LIKE ?3 ESCAPE '\\'
                  OR lower(COALESCE(role_id,'')) LIKE ?3 ESCAPE '\\'
                  OR EXISTS(
                    SELECT 1 FROM agent_assignments assignment
                    WHERE assignment.agent_id=agent_instances.agent_id
                      AND lower(assignment.task) LIKE ?3 ESCAPE '\\'
                  ))";
        let total = connection
            .query_row(
                &format!("SELECT COUNT(*) FROM agent_instances WHERE {where_clause}"),
                params![include_closed, statuses_json, pattern],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count profile agent directory: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {AGENT_COLUMNS} FROM agent_instances
                 WHERE {where_clause}
                 ORDER BY lower(name),agent_id LIMIT ?4 OFFSET ?5"
            ))
            .map_err(|error| format!("prepare paged profile agent directory: {error}"))?;
        let items = statement
            .query_map(
                params![
                    include_closed,
                    statuses_json,
                    pattern,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_agent,
            )
            .map_err(|error| format!("query paged profile agent directory: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode paged profile agent directory: {error}"))?;
        Ok(AgentInstancePage { items, total })
    }

    /// Direct management children in the same active-first ordering used by
    /// Team Context. The total and active count remain exact beyond one page.
    pub(crate) fn management_child_agent_page(
        &self,
        parent_agent_id: &str,
        include_closed: bool,
        offset: usize,
        limit: usize,
    ) -> Result<AgentRelationPage, String> {
        validate_runtime_identifier(parent_agent_id, "parent agent id", 256)?;
        let connection = self.connection()?;
        let total = connection
            .query_row(
                "SELECT COUNT(*) FROM agent_instances
                 WHERE management_owner_agent_id=?1 AND (?2=1 OR state!='closed')",
                params![parent_agent_id, include_closed],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count management children: {error}"))?;
        let active = connection
            .query_row(
                "SELECT COUNT(*) FROM agent_instances
                 WHERE management_owner_agent_id=?1 AND (?2=1 OR state!='closed')
                   AND state IN ('provisioning','active','waiting')",
                params![parent_agent_id, include_closed],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count active management children: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {AGENT_COLUMNS} FROM agent_instances
                 WHERE management_owner_agent_id=?1 AND (?2=1 OR state!='closed')
                 ORDER BY CASE state
                    WHEN 'active' THEN 0 WHEN 'waiting' THEN 1
                    WHEN 'provisioning' THEN 2 ELSE 3 END,
                    lower(name),agent_id LIMIT ?3 OFFSET ?4"
            ))
            .map_err(|error| format!("prepare management child page: {error}"))?;
        let items = statement
            .query_map(
                params![
                    parent_agent_id,
                    include_closed,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_agent,
            )
            .map_err(|error| format!("query management child page: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode management child page: {error}"))?;
        Ok(AgentRelationPage {
            items,
            total,
            active,
        })
    }

    /// Page an already-authorized relationship set in canonical UI order.
    /// Management descendants are emitted parent-first under active direct
    /// roots; all other durable relationships follow as a stable name/id list.
    pub(crate) fn agent_relationship_page(
        &self,
        owner_agent_id: &str,
        related_agent_ids: &[String],
        offset: usize,
        limit: usize,
    ) -> Result<AgentRelationPage, String> {
        validate_runtime_identifier(owner_agent_id, "relationship owner agent id", 256)?;
        let related_json = serde_json::to_string(related_agent_ids)
            .map_err(|error| format!("encode related agent ids: {error}"))?;
        let connection = self.connection()?;
        let total = connection
            .query_row(
                "SELECT COUNT(DISTINCT agent_id) FROM agent_instances
                 WHERE agent_id!=?1 AND agent_id IN (SELECT value FROM json_each(?2))",
                params![owner_agent_id, related_json],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count agent relationships: {error}"))?;
        let active = connection
            .query_row(
                "SELECT COUNT(DISTINCT agent_id) FROM agent_instances
                 WHERE agent_id!=?1 AND agent_id IN (SELECT value FROM json_each(?2))
                   AND state IN ('provisioning','active','waiting')",
                params![owner_agent_id, related_json],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count active agent relationships: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "WITH RECURSIVE
                 requested(agent_id) AS (
                    SELECT DISTINCT value FROM json_each(?2) WHERE value!=?1
                 ),
                 subtree(agent_id,depth,direct_active,direct_name,direct_id,path) AS (
                    SELECT child.agent_id,1,
                           CASE child.state WHEN 'active' THEN 0 WHEN 'waiting' THEN 1
                                WHEN 'provisioning' THEN 2 ELSE 3 END,
                           lower(child.name),child.agent_id,
                           lower(child.name)||char(31)||child.agent_id
                    FROM agent_instances child
                    JOIN requested ON requested.agent_id=child.agent_id
                    WHERE child.management_owner_agent_id=?1
                    UNION ALL
                    SELECT child.agent_id,parent.depth+1,parent.direct_active,
                           parent.direct_name,parent.direct_id,
                           parent.path||char(30)||lower(child.name)||char(31)||child.agent_id
                    FROM agent_instances child
                    JOIN subtree parent ON child.management_owner_agent_id=parent.agent_id
                    JOIN requested ON requested.agent_id=child.agent_id
                 )
                 SELECT {AGENT_COLUMNS} FROM agent_instances
                 WHERE agent_id IN (SELECT agent_id FROM requested)
                 ORDER BY
                    CASE WHEN agent_id IN (SELECT agent_id FROM subtree) THEN 0 ELSE 1 END,
                    COALESCE((SELECT direct_active FROM subtree WHERE subtree.agent_id=agent_instances.agent_id),0),
                    COALESCE((SELECT direct_name FROM subtree WHERE subtree.agent_id=agent_instances.agent_id),''),
                    COALESCE((SELECT direct_id FROM subtree WHERE subtree.agent_id=agent_instances.agent_id),''),
                    COALESCE((SELECT path FROM subtree WHERE subtree.agent_id=agent_instances.agent_id),''),
                    lower(name),agent_id
                 LIMIT ?3 OFFSET ?4"
            ))
            .map_err(|error| format!("prepare agent relationship page: {error}"))?;
        let items = statement
            .query_map(
                params![
                    owner_agent_id,
                    related_json,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_agent,
            )
            .map_err(|error| format!("query agent relationship page: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent relationship page: {error}"))?;
        Ok(AgentRelationPage {
            items,
            total,
            active,
        })
    }

    #[cfg(test)]
    pub(crate) fn list_agent_instances_for_root(
        &self,
        root_session_id: &str,
        include_closed: bool,
        limit: usize,
    ) -> Result<Vec<AgentInstanceRecord>, String> {
        validate_runtime_identifier(root_session_id, "root session id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {AGENT_COLUMNS} FROM agent_instances
                 WHERE root_session_id=?1 AND (?2=1 OR state!='closed')
                 ORDER BY CASE state
                    WHEN 'active' THEN 0 WHEN 'waiting' THEN 1
                    WHEN 'provisioning' THEN 2 WHEN 'idle' THEN 3 ELSE 4 END,
                    created_at,agent_id LIMIT ?3"
            ))
            .map_err(|error| format!("prepare root agent directory: {error}"))?;
        statement
            .query_map(
                params![
                    root_session_id,
                    include_closed,
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256),
                ],
                map_agent,
            )
            .map_err(|error| format!("query root agent directory: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode root agent directory: {error}"))
    }

    #[cfg(test)]
    pub(crate) fn list_child_agent_instances(
        &self,
        parent_agent_id: &str,
        include_closed: bool,
        limit: usize,
    ) -> Result<Vec<AgentInstanceRecord>, String> {
        validate_runtime_identifier(parent_agent_id, "parent agent id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {AGENT_COLUMNS} FROM agent_instances
                 WHERE spawned_by_agent_id=?1 AND (?2=1 OR state!='closed')
                 ORDER BY created_at,agent_id LIMIT ?3"
            ))
            .map_err(|error| format!("prepare child agent directory: {error}"))?;
        statement
            .query_map(
                params![
                    parent_agent_id,
                    include_closed,
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256),
                ],
                map_agent,
            )
            .map_err(|error| format!("query child agent directory: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode child agent directory: {error}"))
    }

    /// Exact management-owned subtree, including the target, in parent-first
    /// order. Management mutations use this uncapped identity list to perform
    /// cross-store quiescence checks before their transactional WorkerStore
    /// compare-and-set; it is not a paged client projection.
    pub(crate) fn agent_owned_subtree_ids(&self, agent_id: &str) -> Result<Vec<String>, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        let ids = owned_agent_subtree(&connection, agent_id)?;
        if ids.is_empty() {
            return Err(format!("agent '{agent_id}' was not found"));
        }
        Ok(ids)
    }

    /// Exact immutable ownership/management-lineage check. This deliberately
    /// excludes explicit capability grants, which are bounded and
    /// non-transitive; callers use it when ownership itself is the authority.
    pub(crate) fn agent_is_management_ancestor(
        &self,
        actor_agent_id: &str,
        target_agent_id: &str,
    ) -> Result<bool, String> {
        validate_runtime_identifier(actor_agent_id, "actor agent id", 256)?;
        validate_runtime_identifier(target_agent_id, "target agent id", 256)?;
        let connection = self.connection()?;
        agent_is_management_ancestor(&connection, actor_agent_id, target_agent_id)
    }

    pub(crate) fn list_agent_assignments(
        &self,
        agent_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE agent_id=?1 ORDER BY queue_ordinal DESC,assignment_id DESC LIMIT ?2"
            ))
            .map_err(|error| format!("prepare agent assignment history: {error}"))?;
        statement
            .query_map(
                params![agent_id, i64::try_from(limit.clamp(1, 200)).unwrap_or(200)],
                map_assignment,
            )
            .map_err(|error| format!("query agent assignment history: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent assignment history: {error}"))
    }

    /// Reverse-queue-order assignment history with SQL-owned offset paging and
    /// an exact total; reusable agents may accumulate history indefinitely.
    pub(crate) fn agent_assignment_history_page(
        &self,
        agent_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<AgentAssignmentPage, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        let total = connection
            .query_row(
                "SELECT COUNT(*) FROM agent_assignments WHERE agent_id=?1",
                [agent_id],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count agent assignment history: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE agent_id=?1 ORDER BY queue_ordinal DESC,assignment_id DESC
                 LIMIT ?2 OFFSET ?3"
            ))
            .map_err(|error| format!("prepare paged agent assignment history: {error}"))?;
        let items = statement
            .query_map(
                params![
                    agent_id,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_assignment,
            )
            .map_err(|error| format!("query paged agent assignment history: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode paged agent assignment history: {error}"))?;
        Ok(AgentAssignmentPage { items, total })
    }

    /// Exact assignment owning the next provider turn, independent of
    /// presentation history limits.
    pub(crate) fn preferred_agent_assignment(
        &self,
        agent_id: &str,
    ) -> Result<Option<AgentAssignmentRecord>, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        connection
            .query_row(
                &format!(
                    "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                     WHERE agent_id=?1
                       AND status IN ('offered','accepted','queued','running','waiting')
                     ORDER BY CASE status
                        WHEN 'running' THEN 0 WHEN 'waiting' THEN 0
                        WHEN 'accepted' THEN 1 WHEN 'queued' THEN 1 ELSE 2 END,
                        queue_ordinal,assignment_id LIMIT 1"
                ),
                [agent_id],
                map_assignment,
            )
            .optional()
            .map_err(|error| format!("query preferred agent assignment: {error}"))
    }

    pub(crate) fn queued_agent_assignment_count(&self, agent_id: &str) -> Result<u64, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        connection
            .query_row(
                "SELECT COUNT(*) FROM agent_assignments
                 WHERE agent_id=?1 AND status IN ('offered','accepted','queued')",
                [agent_id],
                |row| row.get(0),
            )
            .map_err(|error| format!("count queued agent assignments: {error}"))
    }

    /// Count-backed resource page for projections that must remain bounded
    /// while reporting exact overflow.
    pub(crate) fn workspace_claim_page(
        &self,
        agent_id: Option<&str>,
        workspace_id: Option<&str>,
        include_terminal: bool,
        offset: usize,
        limit: usize,
    ) -> Result<WorkspaceClaimPage, String> {
        if agent_id.is_none() && workspace_id.is_none() {
            return Err("workspace claim inspection requires agentId or workspaceId".to_owned());
        }
        if let Some(agent_id) = agent_id {
            validate_runtime_identifier(agent_id, "agent id", 256)?;
        }
        if let Some(workspace_id) = workspace_id {
            validate_runtime_identifier(workspace_id, "workspace id", 256)?;
        }
        let where_clause = "(?1 IS NULL OR agent_id=?1 OR holder_session_id=(
                SELECT session_id FROM agent_instances WHERE agent_id=?1
               ))
           AND (?2 IS NULL OR workspace_id=?2)
           AND (?3=1 OR state IN ('queued','held'))";
        let connection = self.connection()?;
        let total = connection
            .query_row(
                &format!("SELECT COUNT(*) FROM agent_write_claims WHERE {where_clause}"),
                params![agent_id, workspace_id, include_terminal],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count workspace claim page: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {CLAIM_COLUMNS} FROM agent_write_claims
                 WHERE {where_clause}
                 ORDER BY CASE state WHEN 'held' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END,
                          requested_at,claim_id LIMIT ?4 OFFSET ?5"
            ))
            .map_err(|error| format!("prepare workspace claim page: {error}"))?;
        let items = statement
            .query_map(
                params![
                    agent_id,
                    workspace_id,
                    include_terminal,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_claim,
            )
            .map_err(|error| format!("query workspace claim page: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode workspace claim page: {error}"))?;
        Ok(WorkspaceClaimPage { items, total })
    }
}
