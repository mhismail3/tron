//! Domain schema registry.
//!
//! Request and response contracts are split so the registration path can inspect
//! either side without wading through one monolithic schema file. Deeper
//! per-domain schema modules can be added under this directory as domains are
//! tightened further.

mod request;
mod response;

pub(crate) use request::request_schema_for_method;
pub(crate) use response::response_schema_for_method;
