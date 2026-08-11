//! Complete schema checks for native worker client actions.

use super::*;

pub(super) fn validate_client_action_contract(
    action: WorkerClientAction,
    bundle: &WorkerBundle,
) -> Result<(), String> {
    let (input, output, invalid_inputs, invalid_outputs) = match action {
        WorkerClientAction::SpeechTranscription => (
            json!({
                "audioBase64":"UklGRg==",
                "mimeType":"audio/wav",
                "fileName":"voice.wav"
            }),
            json!({"text":"Hello Tron"}),
            vec![
                json!({}),
                json!({"audioBase64":"UklGRg==","mimeType":"audio/wav"}),
                json!({"audioBase64":7,"mimeType":"audio/wav","fileName":"voice.wav"}),
            ],
            vec![json!({}), json!({"text":7})],
        ),
    };
    let function_id =
        crate::engine::FunctionId::new(format!("worker_kernel::client_action_{}", action.as_str()))
            .map_err(|error| error.to_string())?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "request",
        &bundle.input_schema,
        &input,
    )
    .map_err(|error| {
        format!(
            "client action '{}' input does not match inputSchema: {error}",
            action.as_str()
        )
    })?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "response",
        &bundle.output_schema,
        &output,
    )
    .map_err(|error| {
        format!(
            "client action '{}' output does not match outputSchema: {error}",
            action.as_str()
        )
    })?;
    for invalid in invalid_inputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "request",
            &bundle.input_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "client action '{}' inputSchema accepts invalid client payload {invalid}",
                action.as_str(),
            ));
        }
    }
    for invalid in invalid_outputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "response",
            &bundle.output_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "client action '{}' outputSchema accepts invalid client payload {invalid}",
                action.as_str(),
            ));
        }
    }
    Ok(())
}
