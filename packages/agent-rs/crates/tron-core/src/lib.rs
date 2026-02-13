//! # tron-core
//!
//! Foundation types, errors, branded IDs, and utilities for the Tron agent.
//!
//! This crate provides the shared vocabulary that all other Tron crates depend on:
//!
//! - **Branded IDs**: `EventId`, `SessionId`, `WorkspaceId` as newtypes for type safety
//! - **Messages**: `Message` enum with `User`, `Assistant`, `ToolResult` variants
//! - **Content blocks**: `ContentBlock` enum covering text, images, thinking, tool use/results
//! - **Tool results**: `TronToolResult` with content, details, error/stop flags
//! - **Errors**: `TronError` hierarchy via `thiserror`, RPC error codes
//! - **Stream events**: `StreamEvent` enum for LLM streaming protocol

#![deny(unsafe_code)]
