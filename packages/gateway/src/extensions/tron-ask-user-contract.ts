/** Stable release-owned identity for the inline Ask User capability. */
export const TRON_ASK_USER_INLINE_PATH = "<inline:tron-ask-user>";
export const TRON_ASK_USER_SOURCE = "tron:ask-user.v1";

/** Canonical, non-context record of a question its run was stopped before it was answered
 * (#929). Resuming the run in place restates the newest one so the worker asks it again. */
export const TRON_ASK_USER_INTERRUPTED = "tron.ask-user.interrupted.v1";
