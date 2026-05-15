//! Operation binding for the browser worker.

use super::Deps;
use crate::domains::bindings::operation_bindings;
use serde_json::json;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_status" => |_invocation, _deps| {
            Ok(browser_status_payload())
        },
    ];
}

fn browser_status_payload() -> serde_json::Value {
    json!({
        "hasBrowser": false,
        "isStreaming": false,
    })
}

#[cfg(test)]
mod tests {
    use super::browser_status_payload;

    #[test]
    fn get_status_payload_matches_contract_schema() {
        let payload = browser_status_payload();

        assert_eq!(payload["hasBrowser"], false);
        assert_eq!(payload["isStreaming"], false);
        assert!(payload.get("running").is_none());
        assert!(payload.get("streaming").is_none());
    }
}
