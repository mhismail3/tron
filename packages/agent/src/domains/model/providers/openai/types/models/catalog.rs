//! OpenAI static model catalog assembly.

use std::collections::HashMap;
use std::sync::LazyLock;

use super::OpenAIModelInfo;

#[path = "catalog/frontier.rs"]
mod frontier;
#[path = "catalog/retired.rs"]
mod retired;
#[path = "catalog/specialized.rs"]
mod specialized;
#[path = "catalog/standard.rs"]
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
