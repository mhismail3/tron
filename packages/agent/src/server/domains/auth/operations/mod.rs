//! Auth operation implementations.
//!
//! The auth worker owns credential reads, credential mutation, OAuth flow
//! lifecycle, account selection, and auth stream publication. Operation code
//! should depend on `auth::Deps` fields such as the auth path, OAuth flow
//! store, and stream publisher rather than reaching for the whole server setup.
