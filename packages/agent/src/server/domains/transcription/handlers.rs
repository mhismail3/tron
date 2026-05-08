//! Operation binding for the transcription worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "audio" => |invocation, deps| {
            transcribe_audio_value(&invocation.payload, deps).await
        },
        "list_models" => |_invocation, deps| {
            list_models_value(deps)
        },
        "download_model" => |_invocation, deps| {
            download_model_value(deps)
        },
    ];
}
