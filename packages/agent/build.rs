//! Build script: re-runs when relay environment variables change.

fn main() {
    // Recompile when relay env vars change so option_env!() picks up new values.
    println!("cargo:rerun-if-env-changed=TRON_RELAY_URL");
    println!("cargo:rerun-if-env-changed=TRON_RELAY_SECRET");
    println!("cargo:rerun-if-env-changed=TRON_RELAY_ENVIRONMENT");

    // Capability search embeds its first-party ONNX/tokenizer bundle into the
    // agent binary. Keep Cargo's rebuild boundary explicit so asset updates
    // cannot ship with a stale helper binary.
    for asset in [
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/model.onnx",
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/model.sha256",
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/tokenizer.json",
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/config.json",
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/special_tokens_map.json",
        "assets/capability-search/embeddings/all-MiniLM-L6-v2/tokenizer_config.json",
    ] {
        println!("cargo:rerun-if-changed={asset}");
    }
}
