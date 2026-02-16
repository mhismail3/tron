//! CDP-based browser automation and screencast streaming for the Tron agent.
//!
//! This crate provides:
//! - Chrome discovery on macOS
//! - CDP browser session management (launch Chrome, create pages)
//! - All 18 `BrowseTheWeb` actions via CDP
//! - Screencast frame capture and delivery via broadcast channels
//! - `CdpBrowserDelegate` implementing the `BrowserDelegate` trait

#![deny(unsafe_code)]

pub mod chrome;
pub mod delegate;
pub mod error;
pub mod service;
pub mod session;
pub mod types;
