/** Public post hydration, not authenticated bookmark discovery. Only the numeric
 * post ID leaves this boundary; no caller cookies, headers, or query parameters. */
export type XPostProvider = "fxtwitter" | "x-syndication";
export interface XPostAttempt { provider: XPostProvider; outcome: "ok" | "unavailable" | "rate-limited" | "invalid-response" | "network-error"; retryAt?: string; }
export interface XPublicPost {
  id: string;
  url: string;
  provider?: XPostProvider;
  endpoint?: string;
  text?: string;
  title?: string;
  /** Only ordinary root-post text can be complete. No thread/media guarantee. */
  disposition: "complete" | "partial" | "inaccessible";
  limitations: string[];
  attempts: XPostAttempt[];
  raw?: string;
}
export interface XPostResponse { status: number; body?: string; truncated?: boolean; retryAfter?: string; rateLimitReset?: string; }
export type XPostGet = (url: string, signal: AbortSignal) => Promise<XPostResponse>;

/** X's public embed token is derived from the post ID, not an account secret. */
export function xEmbedToken(id: string): string {
  return (Number(id) / 1e15 * Math.PI).toString(36).replace(/(0+|\.)/g, "");
}
export function isPublicXEmbedUrl(url: URL): boolean {
  const id = url.searchParams.get("id") ?? "";
  return url.origin === "https://cdn.syndication.twimg.com" && url.pathname === "/tweet-result" && /^[1-9][0-9]{0,19}$/.test(id) && url.searchParams.getAll("token").length === 1 && url.searchParams.get("token") === xEmbedToken(id);
}

export function xPostIdentity(input: string): { id: string; url: string } {
  if (typeof input !== "string" || input.length > 4_096) throw new Error("Public X URL exceeds its bound");
  const url = new URL(input);
  if (url.protocol !== "https:" || url.username || url.password || url.port || !["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].includes(url.hostname.toLowerCase())) throw new Error("Public X reads require an https X post URL without credentials");
  for (const key of url.searchParams.keys()) if (/token|secret|password|passwd|auth|signature|credential|session|api.?key|^key$|^sig$/i.test(key)) throw new Error("Public X URL contains a credential parameter");
  const match = url.pathname.match(/^\/(?:[A-Za-z0-9_]{1,50}\/status|i\/web\/status)\/([1-9][0-9]{0,19})(?:\/(?:photo|video)\/[1-4])?\/?$/);
  if (!match) throw new Error("Public X reads require a numeric post permalink, not a profile or bookmark page");
  return { id: match[1]!, url: `https://x.com/i/web/status/${match[1]}` };
}

function object(value: unknown): Record<string, any> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : undefined;
}

function parsePost(raw: string, provider: XPostProvider, id: string): Pick<XPublicPost, "text" | "title" | "disposition" | "limitations"> | undefined {
  let payload: Record<string, any> | undefined;
  try { payload = object(JSON.parse(raw)); } catch { return undefined; }
  if (!payload) return undefined;
  const post = provider === "fxtwitter" ? (payload.code === 200 ? object(payload.tweet) : undefined) : payload;
  if (!post || (provider === "fxtwitter" ? post.id : post.id_str) !== id || post.author?.protected === true || post.user?.protected === true) return undefined;
  if (typeof post.text !== "string" || !post.text.trim() || post.text.length > 100_000) return undefined;
  const limitations: string[] = ["Only this post is retrieved; replies, a complete thread, and linked pages are not fetched."];
  let partial = provider === "x-syndication" || post.is_note_tweet !== false;
  if (provider === "fxtwitter" && post.is_note_tweet === undefined) limitations.push("Provider did not establish whether the post is long-form; completeness is unverified.");
  if (provider === "x-syndication") limitations.push("Syndication is a fallback preview; long-post and Article completeness is not established.");
  let text = post.text.trim();
  const author = provider === "fxtwitter" ? post.author?.screen_name : post.user?.screen_name;
  // Keep nested posts distinct: a quote is context, never another bookmark.
  if (post.quote || post.quoted_tweet || post.quoted_status) {
    partial = true;
    limitations.push("Quoted-post context is retained in raw evidence but has not been independently verified.");
  }
  if (post.article || /https?:\/\/(?:x|twitter)\.com\/i\/article\//i.test(text)) {
    partial = true;
    limitations.push("X Article body/embeds require browser verification; this response is not certified as the full Article.");
    const article = object(post.article);
    if (typeof article?.title === "string") text += `\n\nArticle title: ${article.title.slice(0, 512)}`;
  }
  if (post.media || post.mediaDetails || post.video || post.photos?.length) {
    partial = true;
    limitations.push("Media metadata/URLs are retained, not downloaded, transcribed, or visually analyzed.");
  }
  if (post.is_note_tweet === true) {
    partial = true;
    limitations.push("Long-post text is provider-supplied; verify its ending in X before claiming completeness.");
  }
  return { text, title: typeof author === "string" ? `X post by @${author.slice(0, 50)}` : `X post ${id}`, disposition: partial ? "partial" : "complete", limitations };
}

/** One attempt per provider, sequentially. No retry storm, paid API, or hidden
 * browser login. A weaker fallback must not replace usable FxTwitter evidence. */
export async function lookupPublicXPost(input: string, get: XPostGet, signal: AbortSignal): Promise<XPublicPost> {
  const identity = xPostIdentity(input);
  const attempts: XPostAttempt[] = [];
  const providers: Array<[XPostProvider, string]> = [
    ["fxtwitter", `https://api.fxtwitter.com/status/${identity.id}`],
    ["x-syndication", `https://cdn.syndication.twimg.com/tweet-result?id=${identity.id}&lang=en&token=${xEmbedToken(identity.id)}`],
  ];
  for (const [provider, endpoint] of providers) {
    signal.throwIfAborted();
    let response: XPostResponse;
    try { response = await get(endpoint, signal); }
    catch {
      signal.throwIfAborted();
      attempts.push({ provider, outcome: "network-error" });
      continue;
    }
    signal.throwIfAborted();
    if (response.status === 429) {
      const after = response.retryAfter;
      const afterTime = after && /^\d+(?:\.\d+)?$/.test(after) ? Date.now() + Number(after) * 1_000 : after ? Date.parse(after) : NaN;
      const resetTime = response.rateLimitReset && /^\d+$/.test(response.rateLimitReset) ? Number(response.rateLimitReset) * 1_000 : NaN;
      const retryTime = Math.max(...[afterTime, resetTime].filter(time => Number.isFinite(time) && time > Date.now() && time < 8.64e15));
      attempts.push({ provider, outcome: "rate-limited", ...(Number.isFinite(retryTime) ? { retryAt: new Date(retryTime).toISOString() } : {}) });
      continue;
    }
    if (response.status !== 200) { attempts.push({ provider, outcome: "unavailable" }); continue; }
    const raw = response.body;
    const parsed = !response.truncated && raw && Buffer.byteLength(raw, "utf8") <= 2_000_000 ? parsePost(raw, provider, identity.id) : undefined;
    if (!parsed || raw === undefined) { attempts.push({ provider, outcome: "invalid-response" }); continue; }
    attempts.push({ provider, outcome: "ok" });
    return { ...identity, ...parsed, provider, endpoint, attempts, raw };
  }
  return { ...identity, disposition: "inaccessible", attempts, limitations: ["Public lookup failed. Use the approved signed-in browser; do not infer deletion, an empty bookmark list, or successful capture."] };
}
