//! OpenAI static model catalog assembly.

use std::collections::HashMap;
use std::sync::LazyLock;

use super::OpenAIModelInfo;

mod frontier;
mod retired;
mod specialized;
mod standard;

/// Static model registry.
pub static OPENAI_MODELS: LazyLock<HashMap<&'static str, OpenAIModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    frontier::insert(&mut m);
    standard::insert(&mut m);
    retired::insert(&mut m);
    specialized::insert(&mut m);
    m
});
