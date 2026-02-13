//! # tron-runtime
//!
//! Agent execution loop, session management, and orchestration.
//!
//! - **Agent**: Holds provider, tools, hooks, context manager. Runs the turn loop.
//! - **Turn runner**: Build context -> call LLM -> process stream -> execute tools -> record events
//! - **Tool executor**: Pre/post hooks, cancellation token support
//! - **Stream processor**: Consumes `Stream<StreamEvent>`, accumulates content blocks
//! - **Agent runner**: High-level: skill injection, user content building, interrupt handling
//! - **Orchestrator**: Multi-session management with MPSC channels for event ordering

#![deny(unsafe_code)]
