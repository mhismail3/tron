//! Operation binding for the prompt_library worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "prompt_library::history_list" => prompt_history_list_value(Some(payload), deps).await,
        "prompt_library::history_delete" => prompt_history_delete_value(Some(payload), deps).await,
        "prompt_library::history_clear" => prompt_history_clear_value(deps).await,
        "prompt_library::snippet_list" => prompt_snippet_list_value(deps).await,
        "prompt_library::snippet_get" => prompt_snippet_get_value(Some(payload), deps).await,
        "prompt_library::snippet_create" => prompt_snippet_create_value(Some(payload), deps).await,
        "prompt_library::snippet_update" => prompt_snippet_update_value(Some(payload), deps).await,
        "prompt_library::snippet_delete" => prompt_snippet_delete_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("prompt-library method {method} is not engine-owned"),
        }),
    }
}
