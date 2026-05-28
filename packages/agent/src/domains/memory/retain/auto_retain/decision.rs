/// Event type string for user-message events. Single source of truth.
pub(super) const USER_MESSAGE_TYPE: &str = "message.user";

/// Event type string for the retain-boundary event.
pub(super) const RETAINED_TYPE: &str = "memory.retained";

/// Inputs to the auto-retain policy. Pure data; no I/O required to build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AutoRetainInput {
    /// `memory.auto_retain_interval` from settings. `0` disables auto-retain.
    pub interval: u32,
    /// Number of `message.user` events appended to the session **since** the
    /// most recent `memory.retained` event (or session start, whichever is
    /// later).
    pub user_messages_since_retain: i64,
    /// True if this session has a `parent_session_id` — i.e., it's a subagent
    /// run. Auto-retain never fires for subagents.
    pub is_subagent: bool,
}

/// Outcome of the policy. `Fire` carries `interval_fired` for the event payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoRetainDecision {
    Fire { interval_fired: u32 },
    Skip(SkipReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// `interval == 0`.
    Disabled,
    /// Session belongs to a subagent.
    Subagent,
    /// No user-visible exchanges since the last retain (`user_messages_since_retain == 0`).
    NoUserMessages,
    /// `user_messages_since_retain < interval`.
    BelowThreshold,
}

impl SkipReason {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            SkipReason::Disabled => "disabled",
            SkipReason::Subagent => "subagent",
            SkipReason::NoUserMessages => "no_user_messages",
            SkipReason::BelowThreshold => "below_threshold",
        }
    }
}

/// Pure policy decision. No I/O.
///
/// Threshold: fire when `user_messages_since_retain >= interval`. The input is
/// already a delta (user messages since the last retain boundary), so the
/// comparison is direct — no subtraction or boundary arithmetic inside the
/// policy.
pub fn should_auto_retain(input: AutoRetainInput) -> AutoRetainDecision {
    if input.is_subagent {
        return AutoRetainDecision::Skip(SkipReason::Subagent);
    }
    if input.interval == 0 {
        return AutoRetainDecision::Skip(SkipReason::Disabled);
    }
    if input.user_messages_since_retain <= 0 {
        return AutoRetainDecision::Skip(SkipReason::NoUserMessages);
    }
    if input.user_messages_since_retain >= i64::from(input.interval) {
        AutoRetainDecision::Fire {
            interval_fired: input.interval,
        }
    } else {
        AutoRetainDecision::Skip(SkipReason::BelowThreshold)
    }
}
