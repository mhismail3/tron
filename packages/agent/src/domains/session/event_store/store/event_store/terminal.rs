//! Durable metadata for native client terminal launches.

use rusqlite::{OptionalExtension, params};

use crate::domains::session::event_store::errors::Result;

use super::EventStore;

#[derive(Clone, Debug)]
pub(crate) struct TerminalRecord {
    pub(crate) id: String,
    pub(crate) session_id: String,
    pub(crate) generation: u64,
    pub(crate) working_directory: String,
    pub(crate) shell: String,
    pub(crate) state: String,
    pub(crate) rows: u16,
    pub(crate) columns: u16,
    pub(crate) earliest_sequence: u64,
    pub(crate) latest_sequence: u64,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) exited_at: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) interruption_reason: Option<String>,
    pub(crate) retained_until: String,
}

impl EventStore {
    pub(crate) fn insert_terminal(&self, row: &TerminalRecord) -> Result<()> {
        self.with_session_write_lock(&row.session_id, || {
            let conn = self.conn()?;
            conn.execute(
                "INSERT INTO terminals(id,session_id,generation,working_directory,shell,state,rows,columns,earliest_sequence,latest_sequence,created_at,updated_at,exited_at,exit_code,interruption_reason,retained_until) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
                params![row.id,row.session_id,row.generation,row.working_directory,row.shell,row.state,row.rows,row.columns,row.earliest_sequence,row.latest_sequence,row.created_at,row.updated_at,row.exited_at,row.exit_code,row.interruption_reason,row.retained_until],
            )?;
            Ok(())
        })
    }

    pub(crate) fn update_terminal_progress(
        &self,
        id: &str,
        earliest: u64,
        latest: u64,
        rows: u16,
        columns: u16,
    ) -> Result<()> {
        let conn = self.conn()?;
        conn.execute("UPDATE terminals SET earliest_sequence=?2,latest_sequence=?3,rows=?4,columns=?5,updated_at=?6 WHERE id=?1", params![id,earliest,latest,rows,columns,now()])?;
        Ok(())
    }

    pub(crate) fn finish_terminal(
        &self,
        id: &str,
        state: &str,
        exit_code: Option<i32>,
        reason: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn()?;
        let timestamp = now();
        let retained = (chrono::Utc::now() + chrono::Duration::hours(24))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        conn.execute("UPDATE terminals SET state=?2,updated_at=?3,exited_at=?3,exit_code=?4,interruption_reason=?5,retained_until=?6 WHERE id=?1", params![id,state,timestamp,exit_code,reason,retained])?;
        Ok(())
    }

    pub(crate) fn list_terminals(&self, session_id: &str) -> Result<Vec<TerminalRecord>> {
        let conn = self.conn()?;
        let mut statement = conn.prepare("SELECT id,session_id,generation,working_directory,shell,state,rows,columns,earliest_sequence,latest_sequence,created_at,updated_at,exited_at,exit_code,interruption_reason,retained_until FROM terminals WHERE session_id=?1 AND retained_until>?2 ORDER BY updated_at DESC")?;
        let rows = statement
            .query_map(params![session_id, now()], decode)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub(crate) fn terminal_by_id(&self, id: &str) -> Result<Option<TerminalRecord>> {
        let conn = self.conn()?;
        conn.query_row("SELECT id,session_id,generation,working_directory,shell,state,rows,columns,earliest_sequence,latest_sequence,created_at,updated_at,exited_at,exit_code,interruption_reason,retained_until FROM terminals WHERE id=?1", [id], decode).optional().map_err(Into::into)
    }

    pub(crate) fn interrupt_running_terminals(&self) -> Result<()> {
        let conn = self.conn()?;
        let timestamp = now();
        let retained = (chrono::Utc::now() + chrono::Duration::hours(24))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        conn.execute("UPDATE terminals SET state='interrupted',updated_at=?1,exited_at=?1,interruption_reason='server_restarted',retained_until=?2 WHERE state='running'", params![timestamp,retained])?;
        Ok(())
    }

    pub(crate) fn purge_expired_terminals(&self) -> Result<Vec<String>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let mut statement =
            tx.prepare("SELECT id FROM terminals WHERE state!='running' AND retained_until<=?1")?;
        let ids = statement
            .query_map([now()], |row| row.get(0))?
            .collect::<std::result::Result<Vec<String>, _>>()?;
        drop(statement);
        for id in &ids {
            tx.execute("DELETE FROM terminals WHERE id=?1", [id])?;
        }
        tx.commit()?;
        Ok(ids)
    }

    pub(crate) fn terminal_ids(&self) -> Result<std::collections::HashSet<String>> {
        let conn = self.conn()?;
        let mut statement = conn.prepare("SELECT id FROM terminals")?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<std::result::Result<_, _>>()?)
    }
}

fn decode(row: &rusqlite::Row<'_>) -> rusqlite::Result<TerminalRecord> {
    Ok(TerminalRecord {
        id: row.get(0)?,
        session_id: row.get(1)?,
        generation: row.get(2)?,
        working_directory: row.get(3)?,
        shell: row.get(4)?,
        state: row.get(5)?,
        rows: row.get(6)?,
        columns: row.get(7)?,
        earliest_sequence: row.get(8)?,
        latest_sequence: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
        exited_at: row.get(12)?,
        exit_code: row.get(13)?,
        interruption_reason: row.get(14)?,
        retained_until: row.get(15)?,
    })
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
