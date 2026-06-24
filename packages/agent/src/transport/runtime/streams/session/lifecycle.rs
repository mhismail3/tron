use super::*;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
        TronEvent::SessionCreated {
            base,
            model,
            working_directory,
            title,
            ..
        } => Some(global(
            event,
            "session.created",
            Some(json!({
                "model": model,
                "workingDirectory": working_directory,
                "title": title,
                "messageCount": 0,
                "inputTokens": 0,
                "outputTokens": 0,
                "cost": 0.0,
                "lastActivity": base.timestamp,
                "isActive": true,
            })),
        )),
        TronEvent::SessionForked { new_session_id, .. } => Some(global(
            event,
            "session.forked",
            Some(json!({
                "newSessionId": new_session_id,
            })),
        )),
        TronEvent::SessionUpdated {
            title,
            model,
            event_count,
            turn_count,
            message_count,
            input_tokens,
            output_tokens,
            last_turn_input_tokens,
            cache_read_tokens,
            cache_creation_tokens,
            cost,
            last_activity,
            is_active,
            last_user_prompt,
            last_assistant_response,
            parent_session_id,
            activity_lines,
            ..
        } => Some(global(
            event,
            "session.updated",
            Some(json!({
                "title": title,
                "model": model,
                "eventCount": event_count,
                "turnCount": turn_count,
                "messageCount": message_count,
                "inputTokens": input_tokens,
                "outputTokens": output_tokens,
                "lastTurnInputTokens": last_turn_input_tokens,
                "cacheReadTokens": cache_read_tokens,
                "cacheCreationTokens": cache_creation_tokens,
                "cost": cost,
                "lastActivity": last_activity,
                "isActive": is_active,
                "lastUserPrompt": last_user_prompt,
                "lastAssistantResponse": last_assistant_response,
                "parentSessionId": parent_session_id,
                "activityLines": activity_lines,
            })),
        )),
        TronEvent::SessionProcessingChanged { is_processing, .. } => Some(global(
            event,
            "session.processing_changed",
            Some(json!({ "isProcessing": is_processing })),
        )),
        TronEvent::SessionSaved { .. } | TronEvent::SessionLoaded { .. } => {
            Some(session_scoped(event, event.event_type(), Some(json!({}))))
        }
        TronEvent::SessionArchived { .. }
        | TronEvent::SessionUnarchived { .. }
        | TronEvent::SessionDeleted { .. } => {
            let wire_type = match event.event_type() {
                "session_archived" => "session.archived",
                "session_unarchived" => "session.unarchived",
                "session_deleted" => "session.deleted",
                other => other,
            };
            Some(global(event, wire_type, Some(json!({}))))
        }
        _ => None,
    }
}
