# Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
Rows show a title, optional assessment summary, domain/type, and a bounded
square preview when the Gateway captured a safe JPEG, PNG, or WebP OpenGraph
image. Sources without a preview use a deterministic domain/title fallback.
Routine capture and admission state is intentionally hidden from rows; actionable
limitations appear in **About this source**.

Source details lead with the original link and an existing assessment summary.
Saved text, referring sources, and source/about information are progressive
DisclosureGroups. Raw objects, provider representations, revisions, annotations,
and identity fields remain under **Technical details**. Raw files are never
rendered as an unbounded inline text view: the dedicated saved-text reader caps
presentation at 12,000 characters and leaves raw/chunked access behind the
technical path.

An absent assessment is shown honestly as **No summary yet**. Opening a source
never automatically invokes triage or a paid model. **Generate summary** is an
explicit action using the existing assessment owner; it updates only the derived
assessment and does not change admission, archive state, or bookmark membership.
Summaries are interpretation, not replacements for immutable captured evidence.
