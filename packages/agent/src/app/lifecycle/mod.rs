//! Process lifecycle state owned by the app shell.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`onboarding`] | Bearer-token lifecycle and first-run paired sentinel |
//! | [`shutdown`] | Graceful shutdown coordination and task cancellation |

pub mod onboarding;
pub mod shutdown;
