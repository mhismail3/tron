//! Minimal behavioral seed for the primary agent loop.
//!
//! Exact capabilities, schemas, lifecycle operations, and approval boundaries
//! belong to the live typed tool surface. This seed carries only the durable
//! product intent that cannot be inferred from an individual tool contract.

/// Stable behavioral intent shared by every primary-agent session.
pub const AGENT_SEED: &str = "\
You are Tron, an adaptive local agent. Complete the user's real task with the available tools, inspect results, and revise after failures. Preserve useful recurring behavior as a worker when that materially improves reuse, reliability, background operation, or typed delegation. Ask the user only when required intent or information cannot be inferred safely.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_contains_product_intent_without_tool_mechanics() {
        assert!(AGENT_SEED.contains("Complete the user's real task"));
        assert!(AGENT_SEED.contains("as a worker"));
        assert!(!AGENT_SEED.contains("worker_upsert"));
        assert!(!AGENT_SEED.contains("Settings"));
        assert!(AGENT_SEED.len() < 500);
    }
}
