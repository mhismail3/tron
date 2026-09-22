# Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
Rows show a title, optional assessment summary, domain/type, and a bounded
square preview when the Gateway captured a safe JPEG, PNG, or WebP page-preview
or X Article cover image. Sources without a preview use a deterministic domain/title fallback.
Routine capture and admission state is intentionally hidden from rows; actionable
limitations appear in **About this source**.

Source details lead with the original link and an existing assessment summary.
Saved text, referring sources, and source/about information are progressive
DisclosureGroups. Raw objects, provider representations, revisions, annotations,
and identity fields remain under **About this source → Technical details**.
The saved-text reader uses the extracted text, including sources without a raw
object, and provides Previous/Next pages of at most 12,000 characters. Raw-file
inspection is separate and bounded; it does not replace the readable source.
Full stored summaries are available in detail; row line limits keep the list compact.

An absent assessment is shown honestly as **No summary yet**. Opening a source
never automatically invokes triage or a paid model. **Generate summary** is an
explicit action using the existing assessment owner; it updates only the derived
assessment and does not change admission, archive state, or bookmark membership.
Summaries are interpretation, not replacements for immutable captured evidence.
Assessment usage prices are fractional cents (`Double`), matching the Gateway's
numeric contract; token counts remain integers. The native RPC regression decodes
a full source page containing both a preview and sub-cent assessment usage.
New assessments carry an `evidenceDigest` of Gateway `JSON.stringify({title, text})`.
iOS reproduces those UTF-8 bytes without Foundation's default slash escaping.
A mismatch with the current title/text withholds the obsolete summary; metadata
and admission changes alone do not invalidate it. Older unbound assessments remain
stored summaries, not a certification of current evidence. The Gateway and native
regressions share a URL, quote, newline, and Unicode digest vector.
