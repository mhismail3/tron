//! Durable, user-confirmed reusable-agent role review proposals.
//!
//! The reviewer contributes only one explicit `agentRole` declaration and a
//! bounded rationale. This ledger pins every immutable participant and owns
//! proposal state; canonical worker publication remains the only activation
//! path.

use super::*;
use serde::{Deserialize, Serialize};

pub(crate) const AGENT_ROLE_REVIEW_SCHEMA_VERSION: &str = "tron.agent_role_review.v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentRoleReviewStatus {
    Proposed,
    Applying,
    Applied,
    Rejected,
    Stale,
}

impl AgentRoleReviewStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Proposed => "proposed",
            Self::Applying => "applying",
            Self::Applied => "applied",
            Self::Rejected => "rejected",
            Self::Stale => "stale",
        }
    }

    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "proposed" => Ok(Self::Proposed),
            "applying" => Ok(Self::Applying),
            "applied" => Ok(Self::Applied),
            "rejected" => Ok(Self::Rejected),
            "stale" => Ok(Self::Stale),
            _ => Err(format!("invalid agent role review status '{value}'")),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentRoleReviewProposalRecord {
    pub(crate) proposal_id: String,
    pub(crate) schema_version: String,
    pub(crate) proposal_hash: String,
    pub(crate) target_worker_id: String,
    pub(crate) target_worker_version: String,
    pub(crate) target_content_hash: String,
    pub(crate) reviewer_worker_id: String,
    pub(crate) reviewer_worker_version: String,
    pub(crate) reviewer_invocation_id: String,
    pub(crate) status: AgentRoleReviewStatus,
    pub(crate) agent_role: WorkerAgentRole,
    pub(crate) rationale: String,
    pub(crate) published_version: Option<String>,
    pub(crate) last_error: Option<String>,
    pub(crate) rejection_reason: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) applied_at: Option<String>,
    pub(crate) rejected_at: Option<String>,
}

pub(crate) struct NewAgentRoleReviewProposal {
    pub(crate) proposal_id: String,
    pub(crate) request_key: String,
    pub(crate) proposal_hash: String,
    pub(crate) target_worker_id: String,
    pub(crate) target_worker_version: String,
    pub(crate) target_content_hash: String,
    pub(crate) reviewer_worker_id: String,
    pub(crate) reviewer_worker_version: String,
    pub(crate) reviewer_invocation_id: String,
    pub(crate) agent_role: WorkerAgentRole,
    pub(crate) rationale: String,
}

pub(crate) struct AgentRoleReviewProposalPage {
    pub(crate) proposals: Vec<AgentRoleReviewProposalRecord>,
    pub(crate) total: u64,
    pub(crate) next_offset: Option<u64>,
}

pub(super) fn install_schema_v20(connection: &rusqlite::Connection) -> Result<(), String> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS worker_agent_role_review_proposals (
                proposal_id TEXT PRIMARY KEY,
                request_key TEXT NOT NULL UNIQUE,
                schema_version TEXT NOT NULL,
                proposal_hash TEXT NOT NULL,
                target_worker_id TEXT NOT NULL,
                target_worker_version TEXT NOT NULL,
                target_content_hash TEXT NOT NULL,
                reviewer_worker_id TEXT NOT NULL,
                reviewer_worker_version TEXT NOT NULL,
                reviewer_invocation_id TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN (
                    'proposed','applying','applied','rejected','stale'
                )),
                agent_role_json TEXT NOT NULL,
                rationale TEXT NOT NULL,
                application_key TEXT UNIQUE,
                rejection_key TEXT UNIQUE,
                published_version TEXT,
                last_error TEXT,
                rejection_reason TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                applied_at TEXT,
                rejected_at TEXT
             );
             CREATE INDEX IF NOT EXISTS worker_agent_role_review_target
                ON worker_agent_role_review_proposals(
                    target_worker_id,created_at DESC,proposal_id DESC
                );
             CREATE INDEX IF NOT EXISTS worker_agent_role_review_status
                ON worker_agent_role_review_proposals(
                    status,updated_at DESC,proposal_id DESC
                );
             CREATE UNIQUE INDEX IF NOT EXISTS worker_agent_role_review_open_target
                ON worker_agent_role_review_proposals(
                    target_worker_id,target_worker_version
                ) WHERE status IN ('proposed','applying');
             UPDATE worker_agent_role_review_proposals
                SET status='proposed',
                    application_key=NULL,
                    last_error=COALESCE(
                        last_error,
                        'engine restarted while role review publication was in progress'
                    ),
                    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
                WHERE status='applying';
             INSERT OR IGNORE INTO worker_schema(version,applied_at)
                VALUES(20,strftime('%Y-%m-%dT%H:%M:%fZ','now'));",
        )
        .map_err(|error| format!("initialize agent role review schema v20: {error}"))
}

impl WorkerStore {
    pub(crate) fn validate_agent_role_review_declaration(
        &self,
        target: &WorkerBundle,
        agent_role: &WorkerAgentRole,
    ) -> Result<(), String> {
        if !matches!(target.runner, WorkerRunner::Agent { .. }) || target.agent_role.is_some() {
            return Err(
                "role review target must be an agent runner without an agentRole declaration"
                    .to_owned(),
            );
        }
        let mut candidate = target.clone();
        candidate.agent_role = Some(agent_role.clone());
        validate_publishable_bundle(&candidate)
    }

    pub(crate) fn create_agent_role_review_proposal(
        &self,
        request: &NewAgentRoleReviewProposal,
    ) -> Result<(AgentRoleReviewProposalRecord, bool), String> {
        validate_role_review_proposal(request)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent role review proposal: {error}"))?;
        if let Some(record) =
            query_role_review_proposal_by_request_key(&transaction, &request.request_key)?
        {
            validate_role_review_replay(&record, request)?;
            transaction
                .commit()
                .map_err(|error| format!("commit agent role review proposal replay: {error}"))?;
            return Ok((record, false));
        }
        if let Some(record) = query_open_role_review_proposal(
            &transaction,
            &request.target_worker_id,
            &request.target_worker_version,
        )? {
            transaction
                .commit()
                .map_err(|error| format!("commit existing agent role review proposal: {error}"))?;
            return Ok((record, false));
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "INSERT INTO worker_agent_role_review_proposals(
                    proposal_id,request_key,schema_version,proposal_hash,
                    target_worker_id,target_worker_version,target_content_hash,
                    reviewer_worker_id,reviewer_worker_version,
                    reviewer_invocation_id,status,
                    agent_role_json,rationale,created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'proposed',?11,?12,?13,?13)",
                params![
                    request.proposal_id,
                    request.request_key,
                    AGENT_ROLE_REVIEW_SCHEMA_VERSION,
                    request.proposal_hash,
                    request.target_worker_id,
                    request.target_worker_version,
                    request.target_content_hash,
                    request.reviewer_worker_id,
                    request.reviewer_worker_version,
                    request.reviewer_invocation_id,
                    serde_json::to_string(&request.agent_role)
                        .map_err(|error| format!("encode proposed agent role: {error}"))?,
                    request.rationale,
                    now,
                ],
            )
            .map_err(|error| format!("insert agent role review proposal: {error}"))?;
        let record = query_role_review_proposal_by_request_key(&transaction, &request.request_key)?
            .ok_or_else(|| "agent role review proposal disappeared".to_owned())?;
        validate_role_review_replay(&record, request)?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent role review proposal: {error}"))?;
        Ok((record, true))
    }

    pub(crate) fn agent_role_review_proposal(
        &self,
        proposal_id: &str,
    ) -> Result<Option<AgentRoleReviewProposalRecord>, String> {
        validate_runtime_identifier(proposal_id, "role review proposal id", 256)?;
        query_role_review_proposal_by_id(&self.connection()?, proposal_id)
    }

    pub(crate) fn latest_agent_role_review_proposal(
        &self,
        worker_id: &str,
    ) -> Result<Option<AgentRoleReviewProposalRecord>, String> {
        validate_identifier(worker_id, "workerId")?;
        self.connection()?
            .query_row(
                &format!(
                    "SELECT {ROLE_REVIEW_COLUMNS}
                     FROM worker_agent_role_review_proposals
                     WHERE target_worker_id=?1
                     ORDER BY created_at DESC,proposal_id DESC LIMIT 1"
                ),
                [worker_id],
                map_role_review_proposal,
            )
            .optional()
            .map_err(|error| format!("load latest agent role review proposal: {error}"))
    }

    pub(crate) fn list_agent_role_review_proposals(
        &self,
        limit: usize,
        offset: u64,
    ) -> Result<AgentRoleReviewProposalPage, String> {
        let limit = limit.clamp(1, 100);
        let connection = self.connection()?;
        let total = connection
            .query_row(
                "SELECT COUNT(*) FROM worker_agent_role_review_proposals",
                [],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("count agent role review proposals: {error}"))?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ROLE_REVIEW_COLUMNS}
                 FROM worker_agent_role_review_proposals
                 ORDER BY created_at DESC,proposal_id DESC LIMIT ?1 OFFSET ?2"
            ))
            .map_err(|error| format!("prepare agent role review proposal page: {error}"))?;
        let proposals = statement
            .query_map(
                params![
                    i64::try_from(limit).unwrap_or(100),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_role_review_proposal,
            )
            .map_err(|error| format!("query agent role review proposal page: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent role review proposal page: {error}"))?;
        let consumed = offset.saturating_add(proposals.len() as u64);
        Ok(AgentRoleReviewProposalPage {
            proposals,
            total,
            next_offset: (consumed < total).then_some(consumed),
        })
    }

    pub(crate) fn begin_agent_role_review_apply(
        &self,
        proposal_id: &str,
        application_key: &str,
    ) -> Result<AgentRoleReviewProposalRecord, String> {
        validate_runtime_identifier(proposal_id, "role review proposal id", 256)?;
        validate_runtime_identifier(application_key, "role review application key", 256)?;
        let connection = self.connection()?;
        let now = chrono::Utc::now().to_rfc3339();
        let changed = connection
            .execute(
                "UPDATE worker_agent_role_review_proposals
                 SET status='applying',application_key=?2,last_error=NULL,updated_at=?3
                 WHERE proposal_id=?1 AND status='proposed'",
                params![proposal_id, application_key, now],
            )
            .map_err(|error| format!("begin agent role review apply: {error}"))?;
        let record = query_role_review_proposal_by_id(&connection, proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))?;
        if changed == 1
            || (record.status == AgentRoleReviewStatus::Applying
                && role_review_application_key(&connection, proposal_id)?.as_deref()
                    == Some(application_key))
        {
            Ok(record)
        } else {
            Err(format!(
                "agent role review proposal '{proposal_id}' cannot apply while {}",
                record.status.as_str()
            ))
        }
    }

    pub(crate) fn restore_agent_role_review_proposed(
        &self,
        proposal_id: &str,
        application_key: &str,
        error: &str,
    ) -> Result<AgentRoleReviewProposalRecord, String> {
        let connection = self.connection()?;
        let now = chrono::Utc::now().to_rfc3339();
        connection
            .execute(
                "UPDATE worker_agent_role_review_proposals
                 SET status='proposed',application_key=NULL,last_error=?3,updated_at=?4
                 WHERE proposal_id=?1 AND status='applying' AND application_key=?2",
                params![
                    proposal_id,
                    application_key,
                    bounded_role_review_text(error, 4_096),
                    now,
                ],
            )
            .map_err(|cause| format!("restore agent role review proposal: {cause}"))?;
        query_role_review_proposal_by_id(&connection, proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))
    }

    pub(crate) fn complete_agent_role_review_apply(
        &self,
        proposal_id: &str,
        published_version: &str,
    ) -> Result<AgentRoleReviewProposalRecord, String> {
        validate_content_version(published_version)?;
        let connection = self.connection()?;
        let now = chrono::Utc::now().to_rfc3339();
        connection
            .execute(
                "UPDATE worker_agent_role_review_proposals
                 SET status='applied',published_version=?2,last_error=NULL,
                     updated_at=?3,applied_at=?3
                 WHERE proposal_id=?1 AND status IN ('proposed','applying')",
                params![proposal_id, published_version, now],
            )
            .map_err(|error| format!("complete agent role review apply: {error}"))?;
        let record = query_role_review_proposal_by_id(&connection, proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))?;
        if record.status == AgentRoleReviewStatus::Applied
            && record.published_version.as_deref() == Some(published_version)
        {
            Ok(record)
        } else {
            Err("agent role review apply completion conflict".to_owned())
        }
    }

    pub(crate) fn mark_agent_role_review_stale(
        &self,
        proposal_id: &str,
        reason: &str,
    ) -> Result<AgentRoleReviewProposalRecord, String> {
        let connection = self.connection()?;
        let now = chrono::Utc::now().to_rfc3339();
        connection
            .execute(
                "UPDATE worker_agent_role_review_proposals
                 SET status='stale',application_key=NULL,last_error=?2,updated_at=?3
                 WHERE proposal_id=?1 AND status IN ('proposed','applying')",
                params![proposal_id, bounded_role_review_text(reason, 4_096), now],
            )
            .map_err(|error| format!("mark agent role review proposal stale: {error}"))?;
        query_role_review_proposal_by_id(&connection, proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))
    }

    pub(crate) fn reject_agent_role_review_proposal(
        &self,
        proposal_id: &str,
        rejection_key: &str,
        reason: Option<&str>,
    ) -> Result<AgentRoleReviewProposalRecord, String> {
        validate_runtime_identifier(proposal_id, "role review proposal id", 256)?;
        validate_runtime_identifier(rejection_key, "role review rejection key", 256)?;
        if reason.is_some_and(|value| value.len() > 512 || value.chars().any(char::is_control)) {
            return Err(
                "role review rejection reason must contain at most 512 UTF-8 bytes without controls"
                    .to_owned(),
            );
        }
        let connection = self.connection()?;
        let now = chrono::Utc::now().to_rfc3339();
        let reason = reason.map(ToOwned::to_owned);
        let changed = connection
            .execute(
                "UPDATE worker_agent_role_review_proposals
                 SET status='rejected',rejection_key=?2,rejection_reason=?3,
                     last_error=NULL,updated_at=?4,rejected_at=?4
                 WHERE proposal_id=?1 AND status='proposed'",
                params![proposal_id, rejection_key, reason.as_deref(), now],
            )
            .map_err(|error| format!("reject agent role review proposal: {error}"))?;
        let record = query_role_review_proposal_by_id(&connection, proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))?;
        if changed == 1
            || (record.status == AgentRoleReviewStatus::Rejected
                && role_review_rejection_key(&connection, proposal_id)?.as_deref()
                    == Some(rejection_key)
                && record.rejection_reason == reason)
        {
            Ok(record)
        } else {
            Err(format!(
                "agent role review proposal '{proposal_id}' cannot reject while {}",
                record.status.as_str()
            ))
        }
    }
}

const ROLE_REVIEW_COLUMNS: &str = "
    proposal_id,schema_version,proposal_hash,target_worker_id,
    target_worker_version,target_content_hash,reviewer_worker_id,
    reviewer_worker_version,reviewer_invocation_id,status,agent_role_json,rationale,
    published_version,last_error,rejection_reason,created_at,updated_at,
    applied_at,rejected_at";

fn query_role_review_proposal_by_id(
    connection: &rusqlite::Connection,
    proposal_id: &str,
) -> Result<Option<AgentRoleReviewProposalRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {ROLE_REVIEW_COLUMNS}
                 FROM worker_agent_role_review_proposals WHERE proposal_id=?1"
            ),
            [proposal_id],
            map_role_review_proposal,
        )
        .optional()
        .map_err(|error| format!("load agent role review proposal: {error}"))
}

fn query_role_review_proposal_by_request_key(
    connection: &rusqlite::Connection,
    request_key: &str,
) -> Result<Option<AgentRoleReviewProposalRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {ROLE_REVIEW_COLUMNS}
                 FROM worker_agent_role_review_proposals WHERE request_key=?1"
            ),
            [request_key],
            map_role_review_proposal,
        )
        .optional()
        .map_err(|error| format!("load agent role review proposal replay: {error}"))
}

fn query_open_role_review_proposal(
    connection: &rusqlite::Connection,
    worker_id: &str,
    worker_version: &str,
) -> Result<Option<AgentRoleReviewProposalRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {ROLE_REVIEW_COLUMNS}
                 FROM worker_agent_role_review_proposals
                 WHERE target_worker_id=?1 AND target_worker_version=?2
                   AND status IN ('proposed','applying')
                 ORDER BY created_at DESC,proposal_id DESC LIMIT 1"
            ),
            params![worker_id, worker_version],
            map_role_review_proposal,
        )
        .optional()
        .map_err(|error| format!("load open agent role review proposal: {error}"))
}

fn validate_role_review_replay(
    record: &AgentRoleReviewProposalRecord,
    request: &NewAgentRoleReviewProposal,
) -> Result<(), String> {
    if record.proposal_id != request.proposal_id
        || record.schema_version != AGENT_ROLE_REVIEW_SCHEMA_VERSION
        || record.proposal_hash != request.proposal_hash
        || record.target_worker_id != request.target_worker_id
        || record.target_worker_version != request.target_worker_version
        || record.target_content_hash != request.target_content_hash
        || record.reviewer_worker_id != request.reviewer_worker_id
        || record.reviewer_worker_version != request.reviewer_worker_version
        || record.reviewer_invocation_id != request.reviewer_invocation_id
        || record.agent_role != request.agent_role
        || record.rationale != request.rationale
    {
        return Err("agent role review proposal idempotency conflict".to_owned());
    }
    Ok(())
}

fn map_role_review_proposal(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentRoleReviewProposalRecord> {
    let status = row.get::<_, String>(9)?;
    let role = row.get::<_, String>(10)?;
    Ok(AgentRoleReviewProposalRecord {
        proposal_id: row.get(0)?,
        schema_version: row.get(1)?,
        proposal_hash: row.get(2)?,
        target_worker_id: row.get(3)?,
        target_worker_version: row.get(4)?,
        target_content_hash: row.get(5)?,
        reviewer_worker_id: row.get(6)?,
        reviewer_worker_version: row.get(7)?,
        reviewer_invocation_id: row.get(8)?,
        status: AgentRoleReviewStatus::parse(&status).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                9,
                rusqlite::types::Type::Text,
                Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, error)),
            )
        })?,
        agent_role: serde_json::from_str(&role).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                10,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        rationale: row.get(11)?,
        published_version: row.get(12)?,
        last_error: row.get(13)?,
        rejection_reason: row.get(14)?,
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
        applied_at: row.get(17)?,
        rejected_at: row.get(18)?,
    })
}

fn role_review_application_key(
    connection: &rusqlite::Connection,
    proposal_id: &str,
) -> Result<Option<String>, String> {
    connection
        .query_row(
            "SELECT application_key FROM worker_agent_role_review_proposals WHERE proposal_id=?1",
            [proposal_id],
            |row| row.get(0),
        )
        .map_err(|error| format!("load agent role review application key: {error}"))
}

fn role_review_rejection_key(
    connection: &rusqlite::Connection,
    proposal_id: &str,
) -> Result<Option<String>, String> {
    connection
        .query_row(
            "SELECT rejection_key FROM worker_agent_role_review_proposals WHERE proposal_id=?1",
            [proposal_id],
            |row| row.get(0),
        )
        .map_err(|error| format!("load agent role review rejection key: {error}"))
}

fn validate_role_review_proposal(request: &NewAgentRoleReviewProposal) -> Result<(), String> {
    validate_runtime_identifier(&request.proposal_id, "role review proposal id", 256)?;
    validate_runtime_identifier(&request.request_key, "role review request key", 256)?;
    validate_identifier(&request.target_worker_id, "role review target workerId")?;
    validate_content_version(&request.target_worker_version)?;
    validate_content_version(&request.target_content_hash)?;
    validate_identifier(&request.reviewer_worker_id, "role review reviewer workerId")?;
    validate_content_version(&request.reviewer_worker_version)?;
    validate_runtime_identifier(
        &request.reviewer_invocation_id,
        "role review reviewer invocation id",
        256,
    )?;
    if request.proposal_hash.len() != 64
        || !request
            .proposal_hash
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err("role review proposal hash must be 64 hexadecimal digits".to_owned());
    }
    if request.rationale.trim().is_empty()
        || request.rationale.len() > 2_000
        || request.rationale.chars().any(char::is_control)
    {
        return Err(
            "role review rationale must contain 1..=2000 UTF-8 bytes without controls".to_owned(),
        );
    }
    Ok(())
}

fn bounded_role_review_text(value: &str, max_bytes: usize) -> String {
    crate::shared::foundation::text::truncate_with_suffix(value, max_bytes, "…")
}
