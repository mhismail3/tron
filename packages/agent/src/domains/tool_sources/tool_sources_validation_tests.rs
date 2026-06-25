use serde_json::json;

use super::*;

#[tokio::test]
async fn proposal_validation_rejects_passive_and_nominal_activation_intent() {
    let fixture = Fixture::new("proposal-passive-intent").await;
    let mut cases = Vec::new();
    let mut payload = proposal_payload();
    payload["sourceIdentity"]["note"] = json!("MCP server registration requested");
    cases.push(("passive-registration", payload));
    let mut payload = proposal_payload();
    payload["sandboxPolicy"]["reviewNote"] = json!("plugin should be enabled");
    cases.push(("passive-enabled", payload));
    let mut payload = proposal_payload();
    payload["declaredTools"][0]["description"] = json!("package installation requested");
    cases.push(("nominal-installation", payload));
    let mut payload = proposal_payload();
    payload["expectedLinkage"]["plan"] = json!("catalog registration requested");
    cases.push(("catalog-registration-request", payload));
    let mut payload = proposal_payload();
    payload["sourceIdentity"]["note"] = json!("worker restart requested");
    cases.push(("nominal-restart", payload));

    for (key, payload) in cases {
        let error = fixture.create_proposal_error(key, payload).await;
        assert!(error.contains("activation intent string"), "{error}");
    }
}

#[tokio::test]
async fn proposal_validation_allows_inert_non_activation_prose() {
    let fixture = Fixture::new("proposal-inert-prose").await;
    let mut payload = proposal_payload();
    payload["sourceIdentity"]["note"] = json!("registration is forbidden until a later slice");
    payload["sandboxPolicy"]["reviewNote"] = json!("no catalog registration");
    payload["declaredTools"][0]["description"] = json!("metadata only; do not execute tool");
    payload["expectedLinkage"]["operatorNote"] = json!("without launch or install authority");
    payload["expectedLinkage"]["negativeRequest"] =
        json!("MCP server registration is not requested");
    payload["expectedLinkage"]["prohibition"] = json!("plugin enablement is prohibited");

    let result = fixture.create_proposal("inert-prose", payload).await;
    assert_eq!(result["activation"]["performed"], json!(false));
}
