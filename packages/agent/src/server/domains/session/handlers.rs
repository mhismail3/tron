//! Operation binding for the session worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "session::create" => session_create_value(Some(payload), deps).await,
        "session::resume" => session_resume_value(Some(payload), deps).await,
        "session::list" => session_list_value(Some(payload), deps).await,
        "session::delete" => session_delete_value(Some(payload), deps).await,
        "session::fork" => session_fork_value(Some(payload), deps).await,
        "session::get_head" => session_get_head_value(Some(payload), deps).await,
        "session::get_state" => session_get_state_value(Some(payload), deps).await,
        "session::get_history" => session_get_history_value(Some(payload), deps).await,
        "session::reconstruct" => session_reconstruct_value(Some(payload), deps).await,
        "session::archive" => session_archive_value(Some(payload), deps).await,
        "session::unarchive" => session_unarchive_value(Some(payload), deps).await,
        "session::archive_older_than" => {
            session_archive_older_than_value(Some(payload), deps).await
        }
        "session::export" => session_export_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("session method {method} is not engine-owned"),
        }),
    }
}
