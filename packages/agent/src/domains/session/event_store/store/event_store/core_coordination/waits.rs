//! Atomic fan-in registration, parking, terminal reconciliation, and wake absorption.

use super::*;

impl EventStore {
    /// Register an assignment/reply-only durable fan-in. The compatibility
    /// wait table still admits worker handles for the current runtime, but this
    /// core API cannot construct one and derives dependency topology directly
    /// from canonical assignment lineage.
    pub(crate) fn register_core_agent_wait(&self, request: &RegisterWait) -> Result<WaitAdmission> {
        validate_admission_key(&request.idempotency_key)?;
        validate_identifier("wait owner agent id", &request.owner_agent_id)?;
        validate_identifier("wait trace id", &request.trace_id)?;
        if request.targets.is_empty() || request.targets.len() > 32 {
            return Err(EventStoreError::InvalidOperation(
                "agent wait requires 1..=32 targets".to_owned(),
            ));
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let owner = require_open_agent(&transaction, &request.owner_agent_id)?;
            let trace_root = query_agent(&transaction, &owner.root_agent_id)?.ok_or_else(|| {
                EventStoreError::Internal("wait owner root agent disappeared".to_owned())
            })?;
            ensure_coordination_trace_in_tx(
                &transaction,
                &request.trace_id,
                &trace_root.agent_id,
                &trace_root.transcript_session_id,
            )?;
            let owner_assignment = request
                .owner_assignment_id
                .as_deref()
                .map(|assignment_id| {
                    query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                        EventStoreError::InvalidOperation(format!(
                            "wait owner assignment '{assignment_id}' was not found"
                        ))
                    })
                })
                .transpose()?;
            if let Some(assignment) = owner_assignment.as_ref() {
                if assignment.agent_id != owner.agent_id {
                    return Err(EventStoreError::InvalidOperation(
                        "wait owner assignment belongs to another agent".to_owned(),
                    ));
                }
                if !matches!(
                    assignment.status,
                    AssignmentStatus::Running | AssignmentStatus::Waiting
                ) {
                    return Err(EventStoreError::InvalidOperation(format!(
                        "wait owner assignment is {}, not active",
                        assignment.status.as_str()
                    )));
                }
                let conflicting_wait = transaction
                    .query_row(
                        "SELECT wait_id FROM coordination_waits
                     WHERE owner_assignment_id=?1 AND disposition='pending'
                       AND idempotency_key!=?2 LIMIT 1",
                        params![assignment.assignment_id, request.idempotency_key],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                if conflicting_wait.is_some() {
                    return Err(EventStoreError::InvalidOperation(
                        "agent assignment already owns a pending coordination wait".to_owned(),
                    ));
                }
            }

            let mut seen = HashSet::new();
            let mut targets = Vec::with_capacity(request.targets.len());
            let mut dependencies = Vec::with_capacity(request.targets.len());
            let mut topology = BTreeSet::new();
            if let Some(owner_assignment_id) = request.owner_assignment_id.as_deref() {
                collect_assignment_topology(&transaction, owner_assignment_id, &mut topology)?;
            }
            for target in &request.targets {
                if !seen.insert(target.clone()) {
                    return Err(EventStoreError::InvalidOperation(
                        "agent wait contains duplicate targets".to_owned(),
                    ));
                }
                match target {
                    WaitTarget::Assignment(assignment_id) => {
                        validate_identifier("wait assignment id", assignment_id)?;
                        let _ =
                            query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                                EventStoreError::InvalidOperation(format!(
                                    "wait assignment '{assignment_id}' was not found"
                                ))
                            })?;
                        collect_assignment_topology(&transaction, assignment_id, &mut topology)?;
                        let target = CoordinationWaitTarget {
                            kind: CoordinationTargetKind::AgentAssignment,
                            id: assignment_id.clone(),
                        };
                        dependencies.push(CoordinationWaitDependency {
                            target: target.clone(),
                            dependency_id: assignment_dependency(assignment_id),
                        });
                        targets.push(target);
                    }
                    WaitTarget::Reply(question_id) => {
                        validate_identifier("wait reply message id", question_id)?;
                        let (source_agent_id, responder_agent_id) = transaction
                            .query_row(
                                "SELECT source_agent_id,target_agent_id
                                 FROM agent_message_metadata
                                 WHERE message_id=?1 AND kind='question'",
                                [question_id],
                                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                            )
                            .optional()?
                            .ok_or_else(|| {
                                EventStoreError::InvalidOperation(format!(
                                    "wait question '{question_id}' was not found"
                                ))
                            })?;
                        if source_agent_id != owner.agent_id {
                            return Err(EventStoreError::InvalidOperation(
                                "only the question sender may wait for its reply".to_owned(),
                            ));
                        }
                        let target = CoordinationWaitTarget {
                            kind: CoordinationTargetKind::Reply,
                            id: question_id.clone(),
                        };
                        dependencies.push(CoordinationWaitDependency {
                            target: target.clone(),
                            dependency_id: agent_dependency(&responder_agent_id),
                        });
                        targets.push(target);
                    }
                }
            }
            let admitted = create_coordination_wait_in_tx(
                &transaction,
                &NewCoordinationWait {
                    idempotency_key: request.idempotency_key.clone(),
                    session_id: owner.transcript_session_id.clone(),
                    owner_agent_id: owner.agent_id.clone(),
                    owner_assignment_id: request.owner_assignment_id.clone(),
                    trace_id: request.trace_id.clone(),
                    autonomous_hop: request.autonomous_hop,
                    mode: match request.mode {
                        WaitMode::All => CoordinationWaitMode::All,
                        WaitMode::Any => CoordinationWaitMode::Any,
                    },
                    targets,
                    owner_dependency_id: agent_dependency(&request.owner_agent_id),
                    dependencies,
                    dependency_edges: topology.into_iter().collect(),
                },
                &[],
            )?;
            let now = chrono::Utc::now().to_rfc3339();
            absorb_core_wait_wakes_in_tx(
                &transaction,
                &admitted.wait.wait_id,
                &owner.agent_id,
                &now,
            )?;
            if let Some(assignment) = owner_assignment.as_ref() {
                let target_status = if admitted.wait.disposition == "pending" {
                    AssignmentStatus::Waiting
                } else {
                    AssignmentStatus::Running
                };
                set_active_assignment_state_in_tx(&transaction, assignment, target_status, &now)?;
            }
            let satisfied_targets =
                query_core_wait_satisfied_targets_in_tx(&transaction, &admitted.wait.wait_id)?;
            transaction.commit()?;
            Ok(WaitAdmission {
                wait_id: admitted.wait.wait_id,
                disposition: admitted.wait.disposition,
                satisfied_targets,
            })
        })
    }
}
