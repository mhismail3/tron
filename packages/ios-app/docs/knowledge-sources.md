# Knowledge dashboard presentation

The dashboard has one top-level segmented row: **Chronicle** and **Library**.
Chronicle's observations, coverage attention list, and bounded coverage stats are
opened from its logo menu. Library chooses **Sources** or **Syntheses** and source
visibility (saved, pending, or archived) from its filter sheet; those choices are
mutually exclusive and never mutate canonical admission.

## Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
It reads the Gateway's bounded row projection (`projection: "sourceRow"`), which
carries only what a row and its detail header need: identity, title, links, a
preview reference, admission, dates, and the current generated summary. A page of
rows no longer transfers each entry's saved text or retained objects. The view
requires the `knowledge-library-rows.v1` capability and presents an explicit
update-the-Gateway placeholder without it rather than falling back to the slower
full-record read.

Opening the tab is not gated on the network. The accepted first page of each
profile and filter is kept in a bounded local cache (at most eight filters per
Gateway, one page each, with a size cap) and presented immediately while the
Gateway's page replaces it in the background; the loading state appears only when
nothing is cached. A cached page is never presented for a different Gateway
profile, and it retires with the profile.

Row images are content-addressed by the object hash the Gateway published, so an
image is fetched at most once per Gateway, is never stale, and is verified against
its own name before display. Rows that mount together coalesce into bounded
batches of at most sixteen, the decoded window is bounded in memory, and the
recent library is bounded on disk. An image the Gateway refuses is remembered
instead of retried on every scroll, and the retained demand is retried once when
the connection returns.

Search waits for a settled query (300 ms, at least two characters) so a typed word
costs one request rather than one per keystroke, cancels the superseded read, and
paginates through the same cursor contract as the catalogue. Library rows load the
next page before the reader reaches the end, so there is no Load more button in
Sources.

A committed Knowledge mutation refreshes only what changed. The event carries the
Gateway's state revision and the changed record ids: a page that already has that
revision stays exactly as it is (no scroll movement), named rows are patched in
place, and anything else — a new row this page has never seen, an older Gateway
that sends no revision, a changed row while a search filter is active — merges a
fresh first page beneath the rows the reader already reached. Chronicle and
Syntheses keep full records, and their status read is only performed by the
Chronicle surfaces that display it.
Rows remain compact: a title of at most two lines and one domain/type line,
with subtle freshness and verdict text beside a bounded square preview. The row
projection also carries vocabulary tag labels, save/capture age, `hasTake`, and
`tagsStale`; no source body is needed to render them. The preview is the
Gateway-captured safe JPEG, PNG, or WebP page preview or X Article cover image;
sources without one use a deterministic domain/title fallback. Intake
assessments and routine capture/admission state are not shown in rows.

The **Entry Detail** sheet opens from the row the reader touched: the header, the
link, and the current summary the row already carries are presented at once, and
the full record (`knowledge.read` at the row's exact revision, with the admission
authority the row reported) replaces them as soon as it arrives. It leads with one
compact header container: the title
with a pill naming the original link's domain directly beneath it, and a square
preview that spans exactly from the title's top to the pill's bottom. The pill opens the
page in the in-app browser (`TronSafariView`, the same full-bleed
`SFSafariViewController` sheet public webpage displays use). The original link
is the source of truth. The Gateway keeps the captured bytes and readable
extraction as a backup and as model input, but the sheet does not expose them as
reading surfaces: a raw HTML object is not readable, and page extraction
includes site chrome. Everything else is inline in the same sheet, with no secondary details sheet:
the **Summary** group (generated summary or Generate/Regenerate action), a
permanent **Your take** editor, vocabulary-backed tags and their updating
state, a verdict control, a replacement picker (bounded source search including
archived entries), Research / Personal scope and archive controls, and
a **Details** table with type, publication/save/capture dates, current freshness
and age basis, capture state, origin, media type, and revision. Saved notes,
related entries, links and incomplete-capture coverage remain below. Related
entry titles resolve in one bounded rows request rather than one read per title.
For redirected connector captures, the original-link pill uses the requested URL
recorded for that exact saved-item identity in origin provenance; the resolved
page URI remains capture metadata. Unrelated referral origins are never used as
the original link, and the same HTTP(S)-only URL safety policy still applies.
The Raindrop `created` timestamp is the originating save time, not a publication
date. Historical Raindrop records with the old misfiled `created` timestamp are
not mislabeled as publication dates; absent origin-save dates stay absent and
Tron capture time is labeled separately.

Opening a source never invokes model generation. **Generate AI summary** starts
the Gateway-owned background job and returns immediately; progress belongs only
to that action, and the durable job continues after sheet dismissal, app
backgrounding, or reconnect. Reopening queries `knowledge.curation.jobs`; a
completed revision is loaded and propagated through `knowledge.changed`. A
repeated tap while the command is pending shares its command ID. Failure shows
Retry without clearing an existing summary or tags. Summary generation never
fetches linked pages or implies complete thread/discussion coverage. The bounded
result is persisted separately from the Jev intake assessment, with its source
revision, evidence digest, generation time, and full/sampled coverage. A stale
summary is withheld when its title/text evidence changes, and the button becomes
**Regenerate AI summary**. Summary text and controlled tags are separate
interpretations; tags come from the canonical Knowledge vocabulary, not the
summary object. Partial or bounded excerpts are
labeled sampled; linked pages are never inferred as covered.
Your take autosaves after a short idle pause and when the sheet is dismissed.
A failed save keeps a process-local draft with Retry; a stale-revision conflict
shows the Gateway's current take and keeps the draft available for deliberate
retry against the latest revision. A successful take write leaves the row's
canonical `tagsStale` projection intact. The **Updating tags** indicator is shown
only while the Gateway-owned K4 tag-job query reports that source's job as
running; the refreshed row projection then reports the new vocabulary selections.
If no job can start or the job fails, the sheet shows the stale/re-tagging state
instead of a timer-based progress claim. Verdict, placement and admission use
receipted `knowledge.source.curate` operations; free-form tags and client-side summary
writes are not supported. Each async presentation read is fenced by its
presentation activity and Gateway identity, while accepted mutations remain
owned by the Gateway receipt/job authority.

Assessment usage prices are fractional cents (`Double`), matching the Gateway's
numeric contract; token counts remain integers. The native RPC regression decodes
a full source page containing both a preview and sub-cent assessment usage.
New assessments carry an `evidenceDigest` of Gateway `JSON.stringify({title, text})`.
iOS reproduces those UTF-8 bytes without Foundation's default slash escaping.
A mismatch with the current title/text withholds the obsolete summary; metadata
and admission changes alone do not invalidate it. Older unbound assessments remain
stored summaries, not a certification of current evidence. The Gateway and native
regressions share a URL, quote, newline, and Unicode digest vector.

Entry Detail's background work and autosave are validated out of process by
`TronKnowledgeDetailUITests` against the hosted scripted Gateway; see
[iOS development](development.md).

Knowledge Configuration stores the source-summary provider/model in
`KnowledgeConfig.enrichment.model`, separate from the observer model. Its
Summary model row shows the catalog display name, like the observation Model row, and a divided Clear row in the same group clears the value; the iOS config codec round-trips it
because `knowledge.config` replaces the whole KnowledgeConfig. Summary jobs
refuse when it is unset and never fall back to the observation model.
