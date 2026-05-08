//! Operation binding for the transcription worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "transcription::audio" => transcribe_audio_value(&invocation.payload, deps).await,
        "transcription::list_models" => list_models_value(deps),
        "transcription::download_model" => download_model_value(deps),
        _ => Err(CapabilityError::Internal {
            message: format!("transcription method {method} is not engine-owned"),
        }),
    }
}
