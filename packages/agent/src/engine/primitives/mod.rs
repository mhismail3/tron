//! Engine-owned durable state and stream stores.
//!
//! These stores are direct kernel substrate used by worker dispatch, provider
//! surface overlays, replay, and authenticated stream transport. They are not
//! registered as a second generic model/client function surface.

mod stores;

pub(in crate::engine) use stores::PrimitiveStores;
