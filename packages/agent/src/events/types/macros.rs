/// Declarative macro generating `EventType`, `SessionEventPayload`,
/// `ALL_EVENT_TYPES`, wire-format helpers, domain groups, and typed
/// payload access from a single source of truth.
///
/// # Sections
///
/// - **`events`**: Variants whose payload is deserialized via `serde_json::from_value`.
/// - **`raw_events`**: Variants whose payload is passed through as raw `Value`.
///   (Only `MemoryLoaded` currently — its schema is intentionally opaque.)
/// - **`domain_groups`**: Named boolean methods grouping variants into domains.
macro_rules! define_events {
    (
        events {
            $(
                $(#[doc = $doc:literal])*
                $variant:ident => $wire:literal => $payload_ty:ty
            ),* $(,)?
        }
        raw_events {
            $(
                $(#[doc = $rdoc:literal])*
                $rv:ident => $rw:literal => $rp:ty
            ),* $(,)?
        }
        domain_groups {
            $(
                $(#[doc = $gdoc:literal])*
                $method:ident => [$($gv:ident),* $(,)?]
            ),* $(,)?
        }
    ) => {
        // ── EventType enum ──────────────────────────────────────────

        /// Discriminator for all 60 persisted session event types.
        ///
        /// Each variant serializes to its wire string (e.g. `"session.start"`)
        /// for compatibility with TypeScript and iOS clients.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub enum EventType {
            $(
                $(#[doc = $doc])*
                #[serde(rename = $wire)]
                $variant,
            )*
            $(
                $(#[doc = $rdoc])*
                #[serde(rename = $rw)]
                $rv,
            )*
        }

        // ── ALL_EVENT_TYPES constant ────────────────────────────────

        /// All event type variants in definition order.
        pub const ALL_EVENT_TYPES: [EventType; { [$($wire,)* $($rw,)*].len() }] = [
            $(EventType::$variant,)*
            $(EventType::$rv,)*
        ];

        // ── EventType methods ───────────────────────────────────────

        impl EventType {
            /// Canonical wire string (e.g. `"session.start"`).
            #[must_use]
            pub fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $wire,)*
                    $(Self::$rv => $rw,)*
                }
            }

            /// Domain prefix (e.g. `"session"`, `"message"`).
            #[must_use]
            pub fn domain(self) -> &'static str {
                let s = self.as_str();
                // All wire strings contain exactly one dot.
                match s.find('.') {
                    Some(i) => &s[..i],
                    None => s,
                }
            }

            // ── Domain group methods ────────────────────────────────

            $(
                $(#[doc = $gdoc])*
                #[must_use]
                pub fn $method(self) -> bool {
                    matches!(self, $(Self::$gv)|*)
                }
            )*
        }

        impl std::fmt::Display for EventType {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl std::str::FromStr for EventType {
            type Err = String;

            fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
                match s {
                    $($wire => Ok(Self::$variant),)*
                    $($rw => Ok(Self::$rv),)*
                    _ => Err(format!("unknown event type: {s}")),
                }
            }
        }

        // ── SessionEventPayload enum ────────────────────────────────

        /// Typed payload enum for compile-time-safe access.
        ///
        /// Obtained via [`SessionEvent::typed_payload()`] or
        /// [`SessionEvent::into_typed_payload()`].
        #[derive(Clone, Debug, PartialEq)]
        pub enum SessionEventPayload {
            $(
                $(#[doc = $doc])*
                $variant($payload_ty),
            )*
            $(
                $(#[doc = $rdoc])*
                $rv($rp),
            )*
        }

        // ── SessionEvent::typed_payload / into_typed_payload ────────

        impl SessionEvent {
            /// Deserialize the payload into the typed variant (cloning).
            #[allow(clippy::too_many_lines)]
            pub fn typed_payload(&self) -> std::result::Result<SessionEventPayload, serde_json::Error> {
                match self.event_type {
                    $(
                        EventType::$variant => Ok(SessionEventPayload::$variant(
                            serde_json::from_value(self.payload.clone())?,
                        )),
                    )*
                    $(
                        EventType::$rv => Ok(SessionEventPayload::$rv(self.payload.clone())),
                    )*
                }
            }

            /// Deserialize the payload into the typed variant (consuming).
            #[allow(clippy::too_many_lines)]
            pub fn into_typed_payload(self) -> std::result::Result<SessionEventPayload, serde_json::Error> {
                match self.event_type {
                    $(
                        EventType::$variant => Ok(SessionEventPayload::$variant(
                            serde_json::from_value(self.payload)?,
                        )),
                    )*
                    $(
                        EventType::$rv => Ok(SessionEventPayload::$rv(self.payload)),
                    )*
                }
            }
        }
    };
}
