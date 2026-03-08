//! `ManageCalendar` tool — read/write calendar events via iOS EventKit.
//!
//! Uses the `DeviceDelegate` to send requests to iOS and await responses.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{DeviceDelegate, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::validation::{get_optional_string, validate_required_string};

pub struct ManageCalendarTool {
    delegate: Arc<dyn DeviceDelegate>,
    allow_write: bool,
}

impl ManageCalendarTool {
    pub fn new(delegate: Arc<dyn DeviceDelegate>, allow_write: bool) -> Self {
        Self {
            delegate,
            allow_write,
        }
    }
}

#[async_trait]
impl TronTool for ManageCalendarTool {
    fn name(&self) -> &str {
        "ManageCalendar"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "ManageCalendar",
            "Read and manage calendar events on the user's iOS device.\n\n\
             Actions: list (events in date range), search (by query), freeSlots (find free windows), \
             create (new event), delete (remove event).\n\n\
             Requires calendar permission on the device.",
        )
        .required_property(
            "action",
            json!({
                "type": "string",
                "enum": ["list", "search", "freeSlots", "create", "delete"],
                "description": "Calendar action to perform"
            }),
        )
        .property(
            "dateRange",
            json!({
                "type": "object",
                "properties": {
                    "from": {"type": "string", "description": "Start date (ISO 8601)"},
                    "to": {"type": "string", "description": "End date (ISO 8601)"}
                },
                "description": "Date range for list/search/freeSlots (defaults to today)"
            }),
        )
        .property("query", json!({"type": "string", "description": "Search query for 'search' action"}))
        .property("title", json!({"type": "string", "description": "Event title for 'create' action"}))
        .property("startDate", json!({"type": "string", "description": "Event start (ISO 8601) for 'create'"}))
        .property("endDate", json!({"type": "string", "description": "Event end (ISO 8601) for 'create'"}))
        .property("location", json!({"type": "string", "description": "Event location for 'create'"}))
        .property("notes", json!({"type": "string", "description": "Event notes for 'create'"}))
        .property("eventId", json!({"type": "string", "description": "Event ID for 'delete' action"}))
        .property("duration", json!({"type": "number", "description": "Minimum slot duration in minutes for 'freeSlots'"}))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "calendar action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        // Write actions gated by settings
        if !self.allow_write && matches!(action.as_str(), "create" | "delete") {
            return Ok(error_result(format!(
                "Calendar write access is disabled in settings. Action '{action}' requires integrations.calendar.allowWrite to be enabled."
            )));
        }

        let method = format!("calendar.{action}");
        let result = self.delegate.device_request(&method, params.clone()).await?;

        // Include data in content so the LLM can see it (details is metadata-only)
        let content = serde_json::to_string_pretty(&result).unwrap_or_default();

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(&content),
            ]),
            details: Some(json!({
                "action": action,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{extract_text, make_ctx};
    use std::sync::Mutex;

    struct MockDeviceDelegate {
        last_method: Mutex<Option<String>>,
        response: Value,
    }

    impl MockDeviceDelegate {
        fn with_response(response: Value) -> Self {
            Self {
                last_method: Mutex::new(None),
                response,
            }
        }
    }

    #[async_trait]
    impl DeviceDelegate for MockDeviceDelegate {
        async fn device_request(&self, method: &str, _params: Value) -> Result<Value, ToolError> {
            *self.last_method.lock().unwrap() = Some(method.to_string());
            Ok(self.response.clone())
        }
    }

    #[tokio::test]
    async fn list_events() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([
            {"id": "1", "title": "Meeting", "startDate": "2026-03-07T10:00:00Z"}
        ])));
        let tool = ManageCalendarTool::new(delegate.clone(), false);
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("Meeting"), "should contain event data: {text}");
        assert_eq!(
            *delegate.last_method.lock().unwrap(),
            Some("calendar.list".into())
        );
    }

    #[tokio::test]
    async fn write_rejected_when_disabled() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!({})));
        let tool = ManageCalendarTool::new(delegate, false);
        let r = tool
            .execute(json!({"action": "create", "title": "Test"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn write_allowed_when_enabled() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!({"title": "Test", "id": "1"})));
        let tool = ManageCalendarTool::new(delegate, true);
        let r = tool
            .execute(json!({"action": "create", "title": "Test"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Test"), "should contain event title");
    }

    #[tokio::test]
    async fn missing_action_error() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!(null)));
        let tool = ManageCalendarTool::new(delegate, false);
        let r = tool
            .execute(json!({}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn delete_rejected_when_write_disabled() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!({})));
        let tool = ManageCalendarTool::new(delegate, false);
        let r = tool
            .execute(json!({"action": "delete", "eventId": "1"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn free_slots() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([
            {"from": "2026-03-07T12:00:00Z", "to": "2026-03-07T13:00:00Z"}
        ])));
        let tool = ManageCalendarTool::new(delegate, false);
        let r = tool
            .execute(json!({"action": "freeSlots"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("12:00:00"), "should contain slot data: {text}");
    }
}
