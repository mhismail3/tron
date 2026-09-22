# Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
Rows show a title, optional assessment summary, domain/type, and a deterministic
square fallback thumbnail when no preview image is available. Routine capture and
admission state is intentionally hidden from rows; actionable limitations appear
in **About this source**.

Source details lead with the original link and an existing assessment summary.
Saved text, referring sources, and source/about information are progressive
DisclosureGroups. Raw objects, provider representations, revisions, annotations,
and identity fields remain under **Technical details**. Raw files are never
rendered as an unbounded inline text view: the dedicated saved-text reader caps
presentation at 12,000 characters and leaves raw/chunked access behind the
technical path.

An absent assessment is shown honestly as **No summary yet**. Opening a source
never automatically invokes triage or a paid model. Summary generation remains
an explicit user action owned by the existing assessment flow. Summaries are
interpretation, not replacements for immutable captured evidence.
