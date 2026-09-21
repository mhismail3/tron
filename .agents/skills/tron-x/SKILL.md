---
name: tron-x
description: Read public X posts with FxTwitter-first free lookup and bounded fallbacks; discover private bookmarks only through the user-approved signed-in browser.
---

# X posts and bookmarks

Two separate operations: discovering **which posts the user bookmarked** requires
an authenticated browser; reading a **known public post** does not. Never claim
that the public lookup is an authenticated bookmark connector or that a quote,
reply, recommendation, or media link is another bookmarked post.

## Public post access

Prefer the first-party read-only operation:

```json
{"action":"x","url":"https://x.com/example/status/123456789"}
```

It calls FxTwitter once, then X's public syndication endpoint once if the first
response is unavailable, malformed, mismatched, oversized, or rate-limited.
It uses no API key, account cookies, paid X API, or browser login. Requesting this
lookup discloses the post ID to those public services. Do not send known protected
posts or a private bookmark list there without permission; use the approved
browser for protected content. URLs must be HTTPS X/Twitter post permalinks.
Tracking queries and author spelling are not sent to providers.

The result includes canonical X URL/ID, selected provider/endpoint, exact raw
provider JSON, extracted root-post text, bounded provider-declared outbound URLs,
attempt outcomes, and limitations. Preserve those qualifications in analysis.
`complete` means ordinary root-post text, **not** the thread, linked article, or
media. Long posts, Articles, quotes, and media are conservatively partial pending
browser verification. A syndication response is always partial. Explicit source
capture may retain each bounded external target as its own canonical Source,
relating it to the referring post and preserving connector provenance; redirects
remain subject to per-hop SSRF checks. Inspect raw JSON for links and nested
context, never promote a preview/title to an Article body or a video URL to a
transcript.

Requests share a 15-second operation deadline and 5-second attempt deadlines;
bodies are limited to 2 MB, no redirects are followed, and output beyond 128 KB
fails explicitly rather than silently dropping fields. No immediate same-provider
retry occurs, so 429 never causes a retry storm. Honor cooldowns before another
explicit request; repeated failures require browser/user attention, not loops.

### Retain evidence only when requested

```json
{"action":"captureSource","commandId":"x-capture-example-001","url":"https://x.com/example/status/123456789","scope":"research","publicPostLookup":true}
```

This explicitly opts into public lookup and retains the raw provider response in
the existing source store with root-post text, canonical X URI, provider/coverage
reason, and normal revision/deduplication semantics. A rerun matches the same X
numeric identity across username and `i/web` aliases and preserves admission,
provenance, provider representations, relations, and better prior evidence when
hydration fails. Read the returned source using `read`, and its raw object via
`readObject` with exact source ID/revision,
object hash/media type/byte count and returned offsets. Never submit invented
source text as fetched evidence. Partial records remain partial; the existing
Raindrop intake must not acknowledge/move an item solely because a mirror worked.
This skill does not approve paid assessment, remote writes, or recurring work.

### If the running Gateway does not yet expose `action=x`

Do not rebuild/restart it. Use the already installed generic tools for a bounded
read (not an equivalent canonical source capture):

```json
{"url":"https://api.fxtwitter.com/status/123456789","mode":"raw"}
```

Call `fetch_content`, then `get_search_content` using its responseId. Verify
`code == 200`, `tweet.id` exactly equals the requested ID, and nonempty `tweet.text`.
Keep provider JSON and missing-content qualifications; an HTTP success or tool
success flag is insufficient. If unavailable, prefer the browser fallback below.
The core reader owns the public syndication token computation; do not request
account tokens or imitate a cookie-authenticated private API. A maintainer must
manually update the Gateway before the new typed operations become available.

## Browser discovery and missing-content fallback

Use `agent_browser`, not shell-driven Playwright, a copied cookie jar, or an
unreviewed exporter. Ask for an approved browser/profile if not already specified.
A managed browser and the user's normal Chrome window may have different login
state. Never inspect unrelated profiles or copy their secrets to gain access.

1. Use `open` → `snapshot -i` at `https://x.com/i/bookmarks`. Verify the signed-in
   account and that the bookmarks timeline is actually visible. If redirected to
   login, stop and let the user sign in directly in an approved headed window.
   Do not ask for passwords/cookies in chat or approve security challenges.
2. Start with at most 20 bookmark entries and one page transition. For structured
   membership, inspect only Bookmarks/BookmarkFolderTimeline responses generated
   by X's own navigation: `network requests --filter Bookmarks`, then the exact
   `network request <requestId>` supplied by the tool. If the installed tool does
   not expose response bodies, report that limitation; don't pretend DOM links
   prove full membership. Never save an unrestricted authenticated HAR: it can
   contain cookies and unrelated private data.
3. Parse **top-level bookmark timeline entry IDs**, not every nested tweet in the
   JSON. Preserve unavailable-entry IDs, account identity, folder identity where
   present, enumeration time, page cursor, and explicit partial/end status in a
   bounded session-owned progress artifact without headers or credentials.
   Unknown response shapes, login walls, repeated cursors, timeouts, and rate
   limits are failures/partial coverage—not a complete or empty library.
4. Follow the next page through normal browser scrolling, with fresh snapshots.
   Deduplicate post IDs and checkpoint after each verified page. Resume conservatively
   from the visible timeline/head if a cursor is stale; don't replay guessed raw
   requests. Confirm selected older bookmark IDs before claiming historical coverage.
5. Hydrate public IDs with `knowledge action=x`, sequentially, keeping bookmark
   membership separate from content/provider evidence. Explicit source capture may
   retain provider-declared outbound targets as distinct Sources with evidence and
   relations back to the referring post; it must not treat them as thread members
   or replace bookmark provenance. Never bulk-import before the bounded pilot
   verifies identity, page traversal, content, and rerun behavior.
6. Public source endpoints do not reliably enumerate same-author immediate replies.
   Do not infer a thread from feed adjacency, scrape arbitrary replies or
   recommendations, or claim link completeness. For missing or partial content,
   navigate to the original X permalink in the approved browser. Verify post and
   author identity plus each reply/thread relationship, expand long content through
   actual controls, and extract the Article body or author reply chain only as far
   as verified. Prefer X-generated detail responses when available; otherwise
   label DOM extraction as such. Missing article endings, reply pagination,
   embedded posts, or media remain explicit.

Browser discovery is supervised, best-effort, and not an unattended synchronization
service. Login expiry/private API changes require attention. Do not delete saved
content because a later scan omits an ID. Do not unbookmark, follow, like, post,
change settings, purchase credits, install an extension, or schedule recurrence.

## Validation and ownership

Owning code: `packages/gateway/src/knowledge/x-public-post.ts` (public parsing and
fallback), `source-capture.ts` (safe network/raw evidence), `knowledge-service.ts`
(agent routing). Contract and regression details: `packages/gateway/docs/knowledge.md`.
Live account discovery, Article bodies, and thread completeness must be validated
on the user's account; synthetic tests and two public post reads do not prove them.

Delegated children may lack Gateway tools. The owning session performs authorized
reads and passes only relevant bounded evidence, never credentials. This skill is
project-scoped, not installed globally; the core tool description advertises the
public reader without silently modifying user resources.
