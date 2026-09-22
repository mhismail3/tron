/** Public X hydration. FxEmbed v2 is the only Fx provider contract; the
 * syndication response is an independent, root-only fallback. No credentials,
 * cookies, browser state, or provider-v1 parsing cross this boundary. */
export type XPostProvider = "fxembed-v2" | "x-syndication";
export type XPublicCoverage = "root" | "conversation" | "thread";
export const X_PUBLIC_LINK_MAX_LENGTH = 4_096;
export const X_PUBLIC_MAX_PAGES = 8;
export const X_PUBLIC_MAX_ITEMS = 256;
export const X_PUBLIC_MAX_BODY_BYTES = 2_000_000;
const X_PUBLIC_MAX_ARTICLE_BLOCKS = 512;
const X_PUBLIC_MAX_ARTICLE_TEXT = 1_000_000;
const credentialQueryKey = /^(?:token|api[_-]?key|key|secret|password|passwd|auth|signature|sig|access[_-]?token|credential|session)$/i;

export interface XPostAttempt {
  provider: XPostProvider;
  outcome: "ok" | "unavailable" | "rate-limited" | "invalid-response" | "network-error";
  status?: number;
  page?: number;
  retryAt?: string;
}
export interface XPublicArticle {
  id: string;
  title?: string;
  text: string;
  linkedUrls?: string[];
  /** Provider-declared Article cover URL; fetched only by the bounded source owner. */
  coverURL?: string;
  truncated?: boolean;
  limitations: string[];
}
export interface XPublicPostEntry {
  id: string;
  url: string;
  text: string;
  /** Provider's short-post commentary; absent when the post is Article-only. */
  postText?: string;
  article?: XPublicArticle;
  authorId: string;
  parentId?: string;
  role: "root" | "continuation" | "commentary" | "ancestor";
  selected: boolean;
  linkedUrls?: string[];
  /** Provider endpoint and page that established this post. */
  provenance: { endpoint: string; page: number };
  /** The provider returned more declared links than the bounded result keeps. */
  linksTruncated?: boolean;
}
export interface XPublicLinkedReference { url: string; postId: string; postUrl: string; role: XPublicPostEntry["role"] }
export interface XPublicPost {
  id: string;
  url: string;
  provider?: XPostProvider;
  endpoint?: string;
  text?: string;
  title?: string;
  authorId?: string;
  coverage?: XPublicCoverage;
  coverageComplete?: boolean;
  continuations?: XPublicPostEntry[];
  commentary?: XPublicPostEntry[];
  posts?: XPublicPostEntry[];
  stopReasons?: string[];
  disposition: "complete" | "partial" | "inaccessible";
  limitations: string[];
  /** URLs from the root and verified same-author parent chains only. */
  linkedUrls?: string[];
  /** Keeps the exact post/reply that declared each URL for source provenance. */
  linkedReferences?: XPublicLinkedReference[];
  linkLimitReached?: boolean;
  attempts: XPostAttempt[];
  /** First bounded provider payload, retained for existing callers. */
  raw?: string;
  /** Additional bounded page payloads; never silently discarded. */
  rawPages?: string[];
  /** Readable root content, including an Article body when one is present. */
  readableText?: string;
  article?: XPublicArticle;
}
export interface XPostResponse { status: number; body?: string; truncated?: boolean; retryAfter?: string; rateLimitReset?: string }
export type XPostGet = (url: string, signal: AbortSignal) => Promise<XPostResponse>;
export interface XPublicLookupOptions {
  coverage?: XPublicCoverage;
  maxPages?: number;
  maxItems?: number;
  maxBodyBytes?: number;
  maxRawBytes?: number;
}

/** X's public embed token is derived from the post ID, not an account secret. */
export function xEmbedToken(id: string): string { return (Number(id) / 1e15 * Math.PI).toString(36).replace(/(0+|\.)/g, "") }
export function isPublicXEmbedUrl(url: URL): boolean {
  const id = url.searchParams.get("id") ?? "";
  return url.origin === "https://cdn.syndication.twimg.com" && url.pathname === "/tweet-result" && /^[1-9][0-9]{0,19}$/.test(id) && url.searchParams.getAll("token").length === 1 && url.searchParams.get("token") === xEmbedToken(id);
}
export function xPostIdentity(input: string): { id: string; url: string } {
  if (typeof input !== "string" || input.length > X_PUBLIC_LINK_MAX_LENGTH) throw new Error("Public X URL exceeds its bound");
  const url = new URL(input);
  if (url.protocol !== "https:" || url.username || url.password || url.port || !["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].includes(url.hostname.toLowerCase())) throw new Error("Public X reads require an https X post URL without credentials");
  for (const key of url.searchParams.keys()) if (/token|secret|password|passwd|auth|signature|credential|session|api.?key|^key$|^sig$/i.test(key)) throw new Error("Public X URL contains a credential parameter");
  const match = url.pathname.match(/^\/(?:[A-Za-z0-9_]{1,50}\/status|i\/web\/status)\/([1-9][0-9]{0,19})(?:\/(?:photo|video)\/[1-4])?\/?$/);
  if (!match) throw new Error("Public X reads require a numeric post permalink, not a profile or bookmark page");
  return { id: match[1]!, url: `https://x.com/i/web/status/${match[1]}` };
}
function object(value: unknown): Record<string, any> | undefined { return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : undefined }
function numericId(value: unknown): string | undefined { return typeof value === "string" && /^[1-9][0-9]{0,19}$/.test(value) ? value : typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? String(value) : undefined }

/** Normalize provider-declared links, preserving declared http(s) instead of
 * inventing HTTPS upgrades. Redirects are resolved later by the source owner. */
export function normalizePublicLinkedUrl(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length === 0 || value.length > X_PUBLIC_LINK_MAX_LENGTH) return undefined;
  try {
    const url = new URL(value);
    if (!(url.protocol === "https:" || url.protocol === "http:") || url.username || url.password || url.port) return undefined;
    for (const key of url.searchParams.keys()) if (credentialQueryKey.test(key)) return undefined;
    if (["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].includes(url.hostname.toLowerCase()) && /\/(?:[^/]+\/)?status\/[1-9][0-9]{0,19}/i.test(url.pathname)) return undefined;
    url.hash = "";
    const normalized = url.toString();
    return normalized.length <= X_PUBLIC_LINK_MAX_LENGTH ? normalized : undefined;
  } catch { return undefined }
}
function articleEntityLinks(article: Record<string, any>): { urls: string[]; truncated: boolean; malformed: boolean } {
  const blocks = Array.isArray(article.content?.blocks) ? article.content.blocks : [];
  const entityMap = article.content?.entityMap;
  const entities = new Map<string, string>(); let malformed = !Array.isArray(blocks) || blocks.length === 0;
  if (Array.isArray(entityMap)) for (const item of entityMap) {
    const entry = object(item); const key = typeof entry?.key === "string" || typeof entry?.key === "number" ? String(entry.key) : undefined;
    const data = object(object(entry?.value)?.data); const url = typeof data?.url === "string" ? data.url : undefined;
    if (!key || !url) { malformed ||= Boolean(entry); continue; } entities.set(key, url);
  } else if (object(entityMap)) for (const [key, item] of Object.entries(entityMap)) {
    const data = object(object(item)?.data); const url = typeof data?.url === "string" ? data.url : undefined;
    if (url) entities.set(key, url); else malformed = true;
  }
  const candidates: unknown[] = [];
  for (const block of blocks) for (const range of Array.isArray(object(block)?.entityRanges) ? object(block)!.entityRanges : []) {
    const key = object(range)?.key; const url = key !== undefined ? entities.get(String(key)) : undefined;
    if (url) candidates.push(url); else if (key !== undefined) malformed = true;
  }
  const links: string[] = [];
  for (const candidate of candidates) { const normalized = normalizePublicLinkedUrl(candidate); if (normalized && !links.includes(normalized)) links.push(normalized); }
  return { urls: links.slice(0, 8), truncated: links.length > 8, malformed };
}
function articleEvidence(post: Record<string, any>): XPublicArticle | undefined {
  const article = object(post.article); if (!article) return undefined;
  const id = numericId(article.id); if (!id) return undefined;
  const rawBlocks = Array.isArray(object(article.content)?.blocks) ? object(article.content)!.blocks : [];
  const limitations: string[] = []; const chunks: string[] = []; let chars = 0;
  if (!rawBlocks.length) limitations.push("Article body blocks were absent or malformed; title/preview metadata is not treated as body text.");
  if (rawBlocks.length > X_PUBLIC_MAX_ARTICLE_BLOCKS) limitations.push(`Article body exceeded the bounded ${X_PUBLIC_MAX_ARTICLE_BLOCKS}-block retention limit.`);
  for (const rawBlock of rawBlocks.slice(0, X_PUBLIC_MAX_ARTICLE_BLOCKS)) {
    const block = object(rawBlock); const text = typeof block?.text === "string" ? block.text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim() : "";
    if (!block || typeof block?.text !== "string") { limitations.push("Some Article blocks were malformed and omitted."); continue; }
    if (!text) continue;
    const remaining = X_PUBLIC_MAX_ARTICLE_TEXT - chars;
    if (remaining <= 0) { limitations.push("Article body exceeded the bounded readable-text limit."); break; }
    chunks.push(text.slice(0, remaining)); chars += Math.min(text.length, remaining);
    if (text.length > remaining) { limitations.push("Article body exceeded the bounded readable-text limit."); break; }
  }
  const links = articleEntityLinks(article);
  const coverCandidate = object(article.cover_media)?.media_url_https ?? object(article.cover_media)?.media_url ?? object(article.cover_media)?.url;
  const coverURL = normalizePublicLinkedUrl(coverCandidate);
  if (links.malformed) limitations.push("Some Article link metadata was malformed or unreferenced; only block-referenced safe links were retained.");
  if (links.truncated) limitations.push("Article-declared links exceeded the bounded retained-link limit.");
  if (article.cover_media || article.media_entities || article.content?.entityMap) limitations.push("Article embeds and media metadata are retained in raw evidence but were not downloaded or interpreted.");
  const text = chunks.join("\n\n");
  return { id, ...(typeof article.title === "string" && article.title.trim() ? { title: article.title.trim().slice(0, 10_000) } : {}), text, ...(coverURL ? { coverURL } : {}), ...(links.urls.length ? { linkedUrls: links.urls } : {}), ...(links.truncated ? { truncated: true } : {}), limitations };
}
function postReadableText(postText: string, article?: XPublicArticle): string | undefined {
  if (!article?.text) return postText || undefined;
  const heading = article.title ? `X Article: ${article.title}` : "X Article";
  return postText ? `${postText}\n\n${heading}\n\n${article.text}` : `${heading}\n\n${article.text}`;
}
function outboundUrls(post: Record<string, any>): { urls: string[]; truncated: boolean } {
  const candidates: unknown[] = [];
  const entities = object(post.entities);
  for (const value of [entities?.urls, object(post.raw_text)?.facets]) if (Array.isArray(value)) for (const item of value) {
    const entry = object(item);
    const candidate = typeof entry?.expanded_url === "string" ? entry.expanded_url : typeof entry?.replacement === "string" ? entry.replacement : undefined;
    if (candidate) candidates.push(candidate);
  }
  const article = articleEvidence(post); if (article?.linkedUrls) candidates.push(...article.linkedUrls);
  const links: string[] = [];
  for (const candidate of candidates) { const normalized = normalizePublicLinkedUrl(candidate); if (normalized && !links.includes(normalized)) links.push(normalized); }
  return { urls: links.slice(0, 8), truncated: links.length > 8 || Boolean(article?.truncated) };
}
function statusEntry(value: unknown, endpoint: string, page: number, role: XPublicPostEntry["role"]): XPublicPostEntry | undefined {
  const post = object(value); if (!post) return undefined;
  const id = numericId(post.id) ?? numericId(post.id_str); const author = object(post?.author) ?? object(post?.user); const authorId = numericId(author?.id);
  const postText = typeof post?.text === "string" ? post.text.trim() : ""; const article = articleEvidence(post); const readable = postReadableText(postText, article);
  if (!id || !authorId || !readable || readable.length > X_PUBLIC_MAX_ARTICLE_TEXT + 100_000 || author?.protected === true) return undefined;
  const reply = object(post?.replying_to); const parentId = numericId(reply?.status) ?? numericId(reply?.id); const links = outboundUrls(post);
  return { id, url: `https://x.com/i/web/status/${id}`, text: readable, ...(postText ? { postText } : {}), ...(article ? { article } : {}), authorId, ...(parentId ? { parentId } : {}), role, selected: false, ...(links.urls.length ? { linkedUrls: links.urls } : {}), ...(links.truncated ? { linksTruncated: true } : {}), provenance: { endpoint, page } };
}
function rootQuality(value: unknown): string[] {
  const post = object(value);
  if (!post) return ["Root post payload was not verifiable."];
  const limitations: string[] = [];
  if (post.is_note_tweet === undefined) limitations.push("Provider did not establish whether the root is long-form; completeness is unverified.");
  else if (post.is_note_tweet === true) limitations.push("Long-post text is provider-supplied; verify its ending in X before claiming completeness.");
  const article = articleEvidence(post);
  if (post.article || /https?:\/\/(?:x|twitter)\.com\/i\/article\//i.test(typeof post.text === "string" ? post.text : "")) limitations.push("X Article body/embeds require browser verification; this response is not certified as the full Article.");
  if (article?.limitations.length) limitations.push(...article.limitations);
  if (post.media || post.mediaDetails || post.video || (Array.isArray(post.photos) && post.photos.length > 0)) limitations.push("Media metadata/URLs are retained, not downloaded, transcribed, or visually analyzed.");
  if (post.quote || post.quoted_tweet || post.quoted_status) limitations.push("Quoted-post context is retained in raw evidence but has not been independently verified.");
  return limitations;
}
function retryAt(response: XPostResponse): string | undefined {
  const after = response.retryAfter && /^\d+(?:\.\d+)?$/.test(response.retryAfter) ? Date.now() + Number(response.retryAfter) * 1_000 : response.retryAfter ? Date.parse(response.retryAfter) : NaN;
  const reset = response.rateLimitReset && /^\d+$/.test(response.rateLimitReset) ? Number(response.rateLimitReset) * 1_000 : NaN;
  const time = Math.max(...[after, reset].filter(value => Number.isFinite(value) && value > Date.now() && value < 8.64e15));
  return Number.isFinite(time) ? new Date(time).toISOString() : undefined;
}
interface V2Page { root: XPublicPostEntry; entries: XPublicPostEntry[]; cursor?: string; rootLimitations: string[]; rootLinksTruncated: boolean }
function parseV2Page(raw: string, id: string, endpoint: string, page: number, coverage: XPublicCoverage): V2Page | undefined {
  let payload: Record<string, any> | undefined;
  try { payload = object(JSON.parse(raw)); } catch { return undefined }
  if (!payload || (payload.code !== undefined && payload.code !== 200)) return undefined;
  const status = statusEntry(payload.status, endpoint, page, "root");
  if (!status || status.id !== id) return undefined;
  const values: unknown[] = [];
  if (coverage === "thread" && Array.isArray(payload.thread)) values.push(...payload.thread);
  if (coverage === "conversation") {
    if (Array.isArray(payload.thread)) values.push(...payload.thread);
    if (Array.isArray(payload.replies)) values.push(...payload.replies);
  }
  const entries: XPublicPostEntry[] = [];
  for (const value of values) {
    const parsed = statusEntry(value, endpoint, page, coverage === "thread" ? "ancestor" : "commentary");
    if (parsed && parsed.id !== id) entries.push(parsed);
  }
  const cursor = object(payload.cursor)?.bottom;
  return { root: status, entries, rootLimitations: rootQuality(payload.status), rootLinksTruncated: Boolean(status.linksTruncated), ...(typeof cursor === "string" && cursor.length > 0 ? { cursor } : {}) };
}
function selectConversation(root: XPublicPostEntry, entries: XPublicPostEntry[], coverage: XPublicCoverage): { selected: XPublicPostEntry[]; commentary: XPublicPostEntry[]; reasons: string[] } {
  const byId = new Map<string, XPublicPostEntry>([[root.id, root], ...entries.map(entry => [entry.id, entry] as const)]);
  const selected = new Set<string>([root.id]);
  const reasons: string[] = [];
  if (coverage === "thread") {
    let parentId = root.parentId;
    const visited = new Set<string>([root.id]);
    while (parentId) {
      if (visited.has(parentId)) { reasons.push("invalid-parent-cycle"); for (const id of visited) if (id !== root.id) selected.delete(id); break; }
      const parent = byId.get(parentId);
      if (!parent) { reasons.push("missing-parent"); break; }
      // Explicit thread coverage is an ancestor chain, not a publication
      // continuation. Intervening authors are valid and must be retained.
      visited.add(parent.id); selected.add(parent.id); parentId = parent.parentId;
    }
  } else if (coverage === "conversation") {
    let changed = true;
    while (changed) {
      changed = false;
      for (const entry of entries) {
        if (entry.authorId !== root.authorId || !entry.parentId || selected.has(entry.id)) continue;
        if (selected.has(entry.parentId)) { selected.add(entry.id); changed = true; }
      }
    }
  }
  for (const entry of entries) {
    if (entry.authorId === root.authorId && !selected.has(entry.id)) {
      if (!entry.parentId || !byId.has(entry.parentId)) reasons.push("missing-parent");
      else if (byId.get(entry.parentId)?.authorId !== root.authorId) reasons.push("author-reply-to-commenter-excluded");
    }
  }
  const selectedEntries = entries.filter(entry => selected.has(entry.id)).map(entry => ({ ...entry, role: coverage === "thread" ? "ancestor" as const : "continuation" as const, selected: true }));
  const commentary = coverage === "root" ? [] : entries.filter(entry => !selected.has(entry.id)).map(entry => ({ ...entry, role: "commentary" as const, selected: false }));
  return { selected: selectedEntries, commentary, reasons: [...new Set(reasons)] };
}
function linkedFromSelected(root: XPublicPostEntry, selected: XPublicPostEntry[]): { urls: string[]; references: XPublicLinkedReference[]; truncated: boolean } {
  const posts = [root, ...selected]; const allUrls: string[] = []; const allReferences: XPublicLinkedReference[] = [];
  for (const post of posts) for (const url of post.linkedUrls ?? []) {
    if (!allUrls.includes(url)) allUrls.push(url);
    if (!allReferences.some(reference => reference.url === url && reference.postId === post.id)) allReferences.push({ url, postId: post.id, postUrl: post.url, role: post.role });
  }
  const urls = allUrls.slice(0, 8);
  const references = allReferences.filter(reference => urls.includes(reference.url)).slice(0, 16);
  return { urls, references, truncated: posts.some(post => post.linksTruncated) || allUrls.length > urls.length || allReferences.filter(reference => urls.includes(reference.url)).length > references.length };
}
function readableConversationText(root: XPublicPostEntry, selected: XPublicPostEntry[]): string {
  return [root.text, ...selected.map(post => `X ${post.role} ${post.id} (${post.url})\n\n${post.text}`)].join("\n\n");
}
function limitations(coverage: XPublicCoverage, reasons: string[], complete: boolean, selectedCount: number): string[] {
  const result = ["FxEmbed v2 verifies the requested numeric post identity. Same-author continuations are selected only through explicit numeric parent links; replies to commenters and unrelated commenters are retained as commentary, not publication continuations."];
  if (coverage === "root") result.push("Only this post is requested; replies, ancestors, and linked pages are outside this coverage.");
  if (coverage === "thread") result.push("Thread coverage is an ancestor chain from the requested endpoint; it does not discover forward descendants.");
  if (coverage === "conversation") result.push("Conversation coverage is provider enumeration, not proof that deleted, hidden, or unreturned replies do not exist.");
  if (complete) result.push(`Provider scope ended after ${selectedCount} selected post${selectedCount === 1 ? "" : "s"}; this is not a claim of universal X coverage.`);
  for (const reason of reasons) if (reason === "missing-parent") result.push("A candidate lacked its explicit parent in the bounded provider pages and was not promoted.");
  return result;
}
function fallbackPost(raw: string, id: string, endpoint: string): XPublicPostEntry | undefined {
  let payload: Record<string, any> | undefined;
  try { payload = object(JSON.parse(raw)); } catch { return undefined }
  if (!payload || (numericId(payload.id_str) ?? numericId(payload.id)) !== id || typeof payload.text !== "string" || !payload.text.trim() || payload.text.length > 100_000) return undefined;
  if (object(payload.author)?.protected === true || object(payload.user)?.protected === true) return undefined;
  const authorId = numericId(object(payload.author)?.id) ?? numericId(object(payload.user)?.id) ?? "unknown";
  const links = outboundUrls(payload);
  return { id, url: `https://x.com/i/web/status/${id}`, text: payload.text.trim(), authorId, role: "root", selected: true, ...(links.urls.length ? { linkedUrls: links.urls } : {}), ...(links.truncated ? { linksTruncated: true } : {}), provenance: { endpoint, page: 1 } };
}

/** Fetch FxEmbed v2 once per page, fencing cursor progress and item/body/time
 * bounds. A valid partial v2 response is never replaced by a weaker fallback. */
export async function lookupPublicXPost(input: string, get: XPostGet, signal: AbortSignal, options: XPublicLookupOptions = {}): Promise<XPublicPost> {
  const identity = xPostIdentity(input);
  const coverage = options.coverage ?? "root";
  const maxPages = options.maxPages ?? X_PUBLIC_MAX_PAGES;
  const maxItems = options.maxItems ?? X_PUBLIC_MAX_ITEMS;
  const maxBodyBytes = options.maxBodyBytes ?? X_PUBLIC_MAX_BODY_BYTES;
  const maxRawBytes = options.maxRawBytes ?? 8_000_000;
  if (!["root", "conversation", "thread"].includes(coverage) || !Number.isSafeInteger(maxPages) || maxPages < 1 || maxPages > X_PUBLIC_MAX_PAGES || !Number.isSafeInteger(maxItems) || maxItems < 1 || maxItems > X_PUBLIC_MAX_ITEMS || !Number.isSafeInteger(maxBodyBytes) || maxBodyBytes < 1 || maxBodyBytes > X_PUBLIC_MAX_BODY_BYTES || !Number.isSafeInteger(maxRawBytes) || maxRawBytes < maxBodyBytes || maxRawBytes > 8_000_000) throw new Error("Invalid bounded public X lookup options");
  const attempts: XPostAttempt[] = []; const pages: string[] = []; let rawTotal = 0;
  const endpointFor = (cursor?: string) => `https://api.fxtwitter.com/2/${coverage === "thread" ? "thread" : "conversation"}/${identity.id}${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`;
  const entries: XPublicPostEntry[] = []; let root: XPublicPostEntry | undefined; let cursor: string | undefined; let stop: string | undefined; let page = 0; let rootLimitations: string[] = []; let rootLinksTruncated = false; const conflictingIds = new Set<string>();
  for (;;) {
    if (coverage === "root" && page > 0) break;
    if (page >= maxPages) { stop = "max-pages"; break; }
    if (page > 0 && entries.length + 1 >= maxItems) { stop = "max-items"; break; }
    const endpoint = endpointFor(cursor); page += 1;
    let response: XPostResponse;
    try { signal.throwIfAborted(); response = await get(endpoint, signal); }
    catch { signal.throwIfAborted(); attempts.push({ provider: "fxembed-v2", outcome: "network-error", page }); stop = "network-error"; break; }
    signal.throwIfAborted();
    if (response.status === 429) { const retry = retryAt(response); attempts.push({ provider: "fxembed-v2", outcome: "rate-limited", status: response.status, page, ...(retry ? { retryAt: retry } : {}) }); stop = "rate-limited"; break; }
    if (response.status !== 200) { attempts.push({ provider: "fxembed-v2", outcome: "unavailable", status: response.status, page }); stop = "unavailable"; break; }
    const raw = response.body;
    const bodyBytes = raw ? Buffer.byteLength(raw, "utf8") : 0;
    const parsed = !response.truncated && raw && bodyBytes <= maxBodyBytes ? parseV2Page(raw, identity.id, endpoint, page, coverage) : undefined;
    if (!parsed) { attempts.push({ provider: "fxembed-v2", outcome: "invalid-response", status: response.status, page }); stop = "invalid-response"; break; }
    attempts.push({ provider: "fxembed-v2", outcome: "ok", status: response.status, page });
    if (rawTotal + bodyBytes > maxRawBytes) { stop = "max-body-bytes"; break; }
    rawTotal += bodyBytes; pages.push(raw!);
    if (!root) root = parsed.root;
    else if (root.authorId !== parsed.root.authorId || root.parentId !== parsed.root.parentId || root.text !== parsed.root.text) conflictingIds.add(root.id);
    rootLimitations = [...new Set([...rootLimitations, ...parsed.rootLimitations])];
    rootLinksTruncated ||= parsed.rootLinksTruncated;
    const beforeEntries = entries.length;
    for (const entry of parsed.entries) {
      if (entries.length >= maxItems - 1) { stop = "max-items"; break; }
      const previous = entries.find(candidate => candidate.id === entry.id);
      if (!previous) entries.push(entry);
      else if (previous.authorId !== entry.authorId || previous.parentId !== entry.parentId || previous.text !== entry.text) conflictingIds.add(entry.id);
    }
    if (stop === "max-items") break;
    if (coverage === "root" || !parsed.cursor) { stop = "cursor-exhausted"; break; }
    if (cursor === parsed.cursor) { stop = "repeated-cursor"; break; }
    if (entries.length === beforeEntries) { stop = "no-progress"; break; }
    if (entries.length + 1 >= maxItems) { stop = "max-items"; break; }
    cursor = parsed.cursor;
  }
  if (root) {
    const safeEntries = entries.filter(entry => !conflictingIds.has(entry.id));
    const selectedResult = selectConversation(root, safeEntries, coverage);
    const selected = selectedResult.selected.slice(0, Math.max(0, maxItems - 1));
    const allPosts = [root, ...selected, ...selectedResult.commentary];
    const linked = linkedFromSelected(root, selected);
    const linkLimitReached = linked.truncated || rootLinksTruncated;
    const reasons = [...new Set([...(stop ? [stop] : []), ...selectedResult.reasons, ...(conflictingIds.size ? ["inconsistent-post"] : [])])];
    const relationshipIncomplete = reasons.includes("missing-parent") || reasons.includes("author-parent-mismatch") || reasons.includes("invalid-parent-cycle") || reasons.includes("inconsistent-post");
    const complete = !relationshipIncomplete && (stop === "cursor-exhausted" || coverage === "root");
    const rootQualityPartial = rootLimitations.length > 0;
    const rootLimitationsExtra = linkLimitReached ? ["Provider-declared outbound links exceeded the bounded retained URL/reference limit; omitted links were not silently treated as complete."] : [];
    return { ...identity, provider: "fxembed-v2", endpoint: endpointFor(), text: root.text, readableText: readableConversationText(root, selected), ...(root.article ? { article: root.article } : {}), title: root.article?.title || `X post by ${root.authorId}`, authorId: root.authorId, coverage, coverageComplete: complete, continuations: selected, commentary: selectedResult.commentary, posts: allPosts, stopReasons: reasons, disposition: coverage === "root" && complete && !rootQualityPartial ? "complete" : "partial", limitations: [...limitations(coverage, reasons, complete, selected.length + 1), ...rootLimitations, ...rootLimitationsExtra], ...(linkLimitReached ? { linkLimitReached: true } : {}), ...(linked.urls.length ? { linkedUrls: linked.urls, linkedReferences: linked.references } : {}), attempts, ...(pages[0] ? { raw: pages[0] } : {}), ...(pages.length > 1 ? { rawPages: pages } : {}) };
  }
  // The independent syndication fallback is root-only and never parses the
  // retired FxTwitter v1 response shape.
  const fallbackEndpoint = `https://cdn.syndication.twimg.com/tweet-result?id=${identity.id}&lang=en&token=${xEmbedToken(identity.id)}`;
  let fallbackResponse: XPostResponse;
  try { signal.throwIfAborted(); fallbackResponse = await get(fallbackEndpoint, signal); }
  catch { signal.throwIfAborted(); attempts.push({ provider: "x-syndication", outcome: "network-error", page: 1 }); return { ...identity, coverage, stopReasons: [...(stop ? [stop] : []), "network-error"], disposition: "inaccessible", attempts, limitations: ["Public v2 and syndication lookup failed; this is not evidence of deletion or an empty bookmark library."] }; }
  signal.throwIfAborted();
  if (fallbackResponse.status === 429) { const retry = retryAt(fallbackResponse); attempts.push({ provider: "x-syndication", outcome: "rate-limited", status: 429, page: 1, ...(retry ? { retryAt: retry } : {}) }); return { ...identity, coverage, stopReasons: [...(stop ? [stop] : []), "rate-limited"], disposition: "inaccessible", attempts, limitations: ["Public lookup was rate-limited; no provider retry was attempted."] }; }
  if (fallbackResponse.status !== 200) { attempts.push({ provider: "x-syndication", outcome: "unavailable", status: fallbackResponse.status, page: 1 }); return { ...identity, coverage, stopReasons: [...(stop ? [stop] : []), "unavailable"], disposition: "inaccessible", attempts, limitations: ["Public lookup failed. Use the approved signed-in browser; do not infer deletion or an empty bookmark list."] }; }
  const fallbackRaw = fallbackResponse.body; const fallback = !fallbackResponse.truncated && fallbackRaw && Buffer.byteLength(fallbackRaw, "utf8") <= maxBodyBytes ? fallbackPost(fallbackRaw, identity.id, fallbackEndpoint) : undefined;
  if (!fallback || !fallbackRaw) { attempts.push({ provider: "x-syndication", outcome: "invalid-response", status: 200, page: 1 }); return { ...identity, coverage, stopReasons: [...(stop ? [stop] : []), "invalid-response"], disposition: "inaccessible", attempts, limitations: ["Public providers returned no verifiable matching post."] }; }
  attempts.push({ provider: "x-syndication", outcome: "ok", status: 200, page: 1 });
  const linked = linkedFromSelected(fallback, []);
  let fallbackPayload: Record<string, any> | undefined;
  try { fallbackPayload = object(JSON.parse(fallbackRaw)); } catch { /* already validated by fallbackPost */ }
  const fallbackLimitations = fallbackPayload ? rootQuality(fallbackPayload) : [];
  return { ...identity, provider: "x-syndication", endpoint: fallbackEndpoint, text: fallback.text, readableText: fallback.text, title: `X post by ${fallback.authorId}`, authorId: fallback.authorId, coverage, coverageComplete: false, continuations: [], commentary: [], posts: [fallback], stopReasons: [...(stop ? [stop] : [])], disposition: "partial", limitations: ["Syndication is a root-only fallback; thread, reply, parent-chain, long-post, Article, and media completeness are not established.", ...fallbackLimitations, ...(stop ? [`FxEmbed v2 stopped with ${stop} before this fallback.`] : []), ...(linked.truncated ? ["Provider-declared outbound links exceeded the bounded retained URL/reference limit."] : []), ...(linked.urls.length ? [`Discovered ${linked.urls.length} bounded outbound URL(s); each target requires separate safe source capture.`] : [])], ...(linked.truncated ? { linkLimitReached: true } : {}), ...(linked.urls.length ? { linkedUrls: linked.urls, linkedReferences: linked.references } : {}), attempts, raw: fallbackRaw };
}
