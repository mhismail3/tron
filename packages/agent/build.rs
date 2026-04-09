fn main() {
    // Recompile when relay env vars change so option_env!() picks up new values.
    println!("cargo:rerun-if-env-changed=TRON_RELAY_URL");
    println!("cargo:rerun-if-env-changed=TRON_RELAY_SECRET");
    println!("cargo:rerun-if-env-changed=TRON_RELAY_ENVIRONMENT");
}
