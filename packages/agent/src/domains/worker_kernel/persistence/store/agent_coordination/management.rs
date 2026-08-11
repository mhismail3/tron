//! Bounded agent-management grants.
//!
//! Batch admission, revocation, authorization, and subtree inspection share one ledger.

use super::*;

impl WorkerStore {
    /// Atomically admit a bounded set of management capabilities. The batch
    /// ledger captures the exact request and resulting grant ids so replay
    /// cannot partially add rights after a crash or silently broaden the set.
    pub(crate) fn grant_agent_management_batch(
        &self,
        request: &NewAgentManagementGrantBatch,
    ) -> Result<Vec<AgentManagementGrantRecord>, String> {
        validate_runtime_identifier(&request.idempotency_key, "management grant batch key", 256)?;
        if request.capabilities.is_empty() || request.capabilities.len() > 4 {
            return Err("management grant batch requires 1..=4 capabilities".to_owned());
        }
        let mut capabilities = request
            .capabilities
            .iter()
            .map(|capability| capability.as_str())
            .collect::<Vec<_>>();
        capabilities.sort_unstable();
        if capabilities.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err("management grant batch contains duplicate capabilities".to_owned());
        }
        let capabilities_json = encode_json(&json!(capabilities))?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent management grant batch: {error}"))?;
        if let Some((target, grantee, grantor, stored_capabilities, result_ids)) = transaction
            .query_row(
                "SELECT target_agent_id,grantee_agent_id,granted_by_agent_id,
                        capabilities_json,result_grant_ids_json
                 FROM agent_management_grant_batches WHERE idempotency_key=?1",
                [&request.idempotency_key],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| format!("load management grant batch replay: {error}"))?
        {
            if target != request.target_agent_id
                || grantee != request.grantee_agent_id
                || grantor != request.granted_by_agent_id
                || stored_capabilities != capabilities_json
            {
                return Err("agent management grant batch idempotency conflict".to_owned());
            }
            let result_ids = serde_json::from_str::<Vec<String>>(&result_ids)
                .map_err(|error| format!("decode management grant batch results: {error}"))?;
            let records = result_ids
                .iter()
                .map(|grant_id| query_management_grant_by_id(&transaction, grant_id))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| "management grant batch lost a result grant".to_owned())?;
            transaction
                .commit()
                .map_err(|error| format!("commit management grant batch replay: {error}"))?;
            return Ok(records);
        }
        require_agent(&transaction, &request.target_agent_id, "management target")?;
        require_agent(
            &transaction,
            &request.grantee_agent_id,
            "management grantee",
        )?;
        require_agent(
            &transaction,
            &request.granted_by_agent_id,
            "management grantor",
        )?;
        if !agent_is_management_ancestor(
            &transaction,
            &request.granted_by_agent_id,
            &request.target_agent_id,
        )? {
            return Err("only an owning agent or ancestor may grant subtree management".to_owned());
        }
        if request.target_agent_id == request.grantee_agent_id {
            return Err(
                "an agent cannot receive an explicit management grant over itself".to_owned(),
            );
        }
        let now = chrono::Utc::now().to_rfc3339();
        let digest = hex::encode(Sha256::digest(request.idempotency_key.as_bytes()));
        let mut records = Vec::with_capacity(request.capabilities.len());
        for capability in &request.capabilities {
            let existing = transaction
                .query_row(
                    &format!(
                        "SELECT {GRANT_COLUMNS} FROM agent_management_grants
                         WHERE target_agent_id=?1 AND grantee_agent_id=?2 AND capability=?3
                           AND revoked_at IS NULL"
                    ),
                    params![
                        request.target_agent_id,
                        request.grantee_agent_id,
                        capability.as_str(),
                    ],
                    map_grant,
                )
                .optional()
                .map_err(|error| format!("load active management grant: {error}"))?;
            let record = if let Some(existing) = existing {
                existing
            } else {
                let idempotency_key = format!(
                    "agent-grant-batch:{}:{}",
                    &digest[..32],
                    capability.as_str()
                );
                transaction
                    .execute(
                        "INSERT INTO agent_management_grants(
                            grant_id,idempotency_key,target_agent_id,grantee_agent_id,
                            granted_by_agent_id,capability,created_at
                         ) VALUES (?1,?2,?3,?4,?5,?6,?7)",
                        params![
                            format!("agent_grant_{}", uuid::Uuid::now_v7()),
                            idempotency_key,
                            request.target_agent_id,
                            request.grantee_agent_id,
                            request.granted_by_agent_id,
                            capability.as_str(),
                            now,
                        ],
                    )
                    .map_err(|error| format!("insert batched agent management grant: {error}"))?;
                query_management_grant_by_key(&transaction, &idempotency_key)?
                    .ok_or_else(|| "batched agent management grant disappeared".to_owned())?
            };
            records.push(record);
        }
        let result_ids = records
            .iter()
            .map(|record| record.grant_id.clone())
            .collect::<Vec<_>>();
        transaction
            .execute(
                "INSERT INTO agent_management_grant_batches(
                    batch_id,idempotency_key,target_agent_id,grantee_agent_id,
                    granted_by_agent_id,capabilities_json,result_grant_ids_json,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    format!("agent_grant_batch_{}", uuid::Uuid::now_v7()),
                    request.idempotency_key,
                    request.target_agent_id,
                    request.grantee_agent_id,
                    request.granted_by_agent_id,
                    capabilities_json,
                    encode_json(&json!(result_ids))?,
                    now,
                ],
            )
            .map_err(|error| format!("persist agent management grant batch: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent management grant batch: {error}"))?;
        Ok(records)
    }

    #[cfg(test)]
    pub(crate) fn grant_agent_management(
        &self,
        request: &NewAgentManagementGrant,
    ) -> Result<AgentManagementGrantRecord, String> {
        validate_runtime_identifier(&request.idempotency_key, "management grant key", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent management grant: {error}"))?;
        require_agent(&transaction, &request.target_agent_id, "management target")?;
        require_agent(
            &transaction,
            &request.grantee_agent_id,
            "management grantee",
        )?;
        require_agent(
            &transaction,
            &request.granted_by_agent_id,
            "management grantor",
        )?;
        if !agent_is_management_ancestor(
            &transaction,
            &request.granted_by_agent_id,
            &request.target_agent_id,
        )? {
            return Err("only an owning agent or ancestor may grant subtree management".to_owned());
        }
        if request.target_agent_id == request.grantee_agent_id {
            return Err(
                "an agent cannot receive an explicit management grant over itself".to_owned(),
            );
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "INSERT OR IGNORE INTO agent_management_grants(
                    grant_id,idempotency_key,target_agent_id,grantee_agent_id,
                    granted_by_agent_id,capability,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7)",
                params![
                    format!("agent_grant_{}", uuid::Uuid::now_v7()),
                    request.idempotency_key,
                    request.target_agent_id,
                    request.grantee_agent_id,
                    request.granted_by_agent_id,
                    request.capability.as_str(),
                    now,
                ],
            )
            .map_err(|error| format!("insert agent management grant: {error}"))?;
        let record = query_management_grant_by_key(&transaction, &request.idempotency_key)?
            .ok_or_else(|| "agent management grant disappeared".to_owned())?;
        if record.target_agent_id != request.target_agent_id
            || record.grantee_agent_id != request.grantee_agent_id
            || record.granted_by_agent_id != request.granted_by_agent_id
            || record.capability != request.capability
        {
            return Err("agent management grant idempotency conflict".to_owned());
        }
        transaction
            .commit()
            .map_err(|error| format!("commit agent management grant: {error}"))?;
        Ok(record)
    }

    pub(crate) fn revoke_agent_management(
        &self,
        grant_id: &str,
        granted_by_agent_id: &str,
    ) -> Result<bool, String> {
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE agent_management_grants
                 SET revoked_at=?3
                 WHERE grant_id=?1 AND granted_by_agent_id=?2 AND revoked_at IS NULL",
                params![grant_id, granted_by_agent_id, now],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("revoke agent management grant: {error}"))
    }

    pub(crate) fn has_agent_management(
        &self,
        actor_agent_id: &str,
        target_agent_id: &str,
        capability: AgentManagementCapability,
    ) -> Result<bool, String> {
        let connection = self.connection()?;
        let owned = agent_is_management_ancestor(&connection, actor_agent_id, target_agent_id)?;
        if owned {
            return Ok(true);
        }
        connection
            .query_row(
                "WITH RECURSIVE ancestry(agent_id,owner_agent_id) AS (
                    SELECT agent_id,management_owner_agent_id
                    FROM agent_instances WHERE agent_id=?1
                    UNION ALL
                    SELECT parent.agent_id,parent.management_owner_agent_id
                    FROM agent_instances parent
                    JOIN ancestry child ON child.owner_agent_id=parent.agent_id
                 )
                 SELECT EXISTS(
                    SELECT 1 FROM agent_management_grants grant_record
                    WHERE grant_record.target_agent_id IN (
                        SELECT agent_id FROM ancestry
                    )
                      AND grant_record.grantee_agent_id=?2
                      AND grant_record.capability=?3
                      AND grant_record.revoked_at IS NULL
                 )",
                params![target_agent_id, actor_agent_id, capability.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("inspect explicit agent management grant: {error}"))
    }

    /// Inspect every active (or historical) grant touching an owned subtree.
    /// This powers authoritative client action/disabled-reason projections.
    pub(crate) fn list_agent_management_grants_for_subtree(
        &self,
        agent_id: &str,
        include_revoked: bool,
        limit: usize,
    ) -> Result<Vec<AgentManagementGrantRecord>, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "WITH RECURSIVE subtree(agent_id) AS (
                    SELECT agent_id FROM agent_instances WHERE agent_id=?1
                    UNION ALL
                    SELECT child.agent_id FROM agent_instances child
                    JOIN subtree parent ON child.management_owner_agent_id=parent.agent_id
                 )
                 SELECT {GRANT_COLUMNS} FROM agent_management_grants
                 WHERE (target_agent_id IN (SELECT agent_id FROM subtree)
                        OR grantee_agent_id IN (SELECT agent_id FROM subtree))
                   AND (?2=1 OR revoked_at IS NULL)
                 ORDER BY created_at DESC,grant_id DESC LIMIT ?3"
            ))
            .map_err(|error| format!("prepare agent subtree management grants: {error}"))?;
        statement
            .query_map(
                params![
                    agent_id,
                    include_revoked,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                ],
                map_grant,
            )
            .map_err(|error| format!("query agent subtree management grants: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent subtree management grants: {error}"))
    }
}
