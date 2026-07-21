//! Process lifecycle state owned by the app shell.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`onboarding`] | Authenticated transport bearer-token lifecycle |
//! | [`shutdown`] | Graceful shutdown coordination and task cancellation |

pub mod onboarding;
pub mod shutdown;
