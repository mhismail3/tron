import { describe, expect, it } from "vitest";
import { extractReadableText } from "./source-capture.js";

/** Failure modes this extractor must catch, written before the implementation:
 *
 * F1  Site chrome (nav/header/footer/aside) dominates the readable budget, so a
 *     GitHub repository page yields navigation text instead of its README.
 * F2  A page with both a wide page container and a narrow article picks the
 *     container, so repository chrome precedes the real article text.
 * F3  A blog page without <main>/<article> keeps its nav and footer text.
 * F4  A docs page keeps its sidebar navigation text.
 * F5  An HTML app shell is presented as an article instead of partial.
 * F6  Chrome removal leaves almost nothing, yet the capture claims "complete".
 * F7  A genuinely short page is downgraded even though its text is the content.
 * F8  A link-dense menu inside otherwise unstructured content survives.
 * F9  Script/style/commented markup leaks into the text or deletes real content.
 * F10 Entity-encoded text is not decoded.
 * F11 Truncation at the readable bound is not reported.
 * F12 Non-HTML media types are rewritten by the HTML path.
 * F13 Uppercase tags or a `>` inside a quoted attribute break the scan.
 * F14 An <article> header (title/byline) is treated as site chrome and dropped.
 * F15 Text inside the <head> (title/meta) is presented as article body.
 * F16 Listing pages with several equal cards lose all but one card.
 * F17 A small <main> beside the real body text wins on name alone.
 * F18 Unbalanced/malformed markup drops content after the malformed tag.
 * F19 A large document is unbounded or pathological to scan.
 */
const encode = (markup: string) => new TextEncoder().encode(markup);
const read = (markup: string, maxChars = 200_000) => extractReadableText(encode(markup), "text/html", maxChars);

/** A GitHub repository page: repository chrome lives inside <main>, and the
 * README lives inside <article> inside that same <main>. */
function githubLike(): string {
  const navLinks = Array.from({ length: 12 }, (_, index) => `<a href="/link-${index}">Repository menu item ${index}</a>`).join("");
  return `<html><head><title>GitHub - example/project · GitHub</title><meta name="description" content="chrome"></head><body>
    <header class="site-header"><a href="/">GitHub Copilot Write better code with AI</a><nav>${navLinks}</nav></header>
    <main id="repo-main">
      <div class="repo-header">example / project Public Notifications You must be signed in to change notification settings Fork 15 Star 175 Code Issues Pull requests Actions Projects Insights</div>
      <nav class="repo-tabs"><a href="#code">Code</a><a href="#issues">Issues</a><a href="#pull">Pull requests</a></nav>
      <article class="markdown-body">
        <header><h1>Project README</h1></header>
        <p>This project turns a product goal into an explicit loss function an agent can optimize against.</p>
        <p>It ships a worked playbook for distilling an existing application in about thirty hours, including the prompts, the evaluation loop and the checkpoints a long-running autonomous agent needs.</p>
        <p>Install it by copying the skill directory into your agent's skills folder and pointing it at the repository you want to distil.</p>
        <footer class="article-footer"><p>Last updated by the maintainers.</p></footer>
      </article>
    </main>
    <footer class="site-footer"><a href="/pricing">Pricing</a><a href="/about">About</a><p>© 2026 Example Inc.</p></footer>
  </body></html>`;
}

function blogLike(): string {
  const menu = Array.from({ length: 9 }, (_, index) => `<li><a href="/tag/${index}">Topic archive ${index}</a></li>`).join("");
  return `<html><head><title>A blog post about caching</title></head><body>
    <div id="page">
      <header><h1>Example Engineering</h1><nav><ul>${menu}</ul></nav></header>
      <div class="post-body">
        <h2>Prompt caching is a layout problem</h2>
        <p>Cache hit rate follows the order of the prompt: stable prefixes first, volatile text last.</p>
      </div>
      <footer><p>Subscribe to our newsletter for weekly updates.</p></footer>
    </div>
  </body></html>`;
}

function docsLike(): string {
  const sidebar = Array.from({ length: 14 }, (_, index) => `<li><a href="/docs/${index}">Sidebar page ${index}</a></li>`).join("");
  return `<html><body>
    <header><a href="/">Docs home</a></header>
    <main><div class="layout"><aside><nav><ul>${sidebar}</ul></nav></aside>
      <section class="content"><h1>Configuration</h1><p>Set the connector scope to the numeric collection identifier.</p></section>
    </div></main>
    <footer><p>Was this page helpful?</p></footer>
  </body></html>`;
}

describe("readable HTML extraction", () => {
  it("drops site chrome and reads the article beside a wide page container (F1, F2, F14, F15)", () => {
    const result = read(githubLike());
    expect(result).toBeDefined();
    expect(result!.text).toContain("turns a product goal into an explicit loss function");
    expect(result!.text).toContain("worked playbook for distilling");
    // The article's own header is its title, not site chrome.
    expect(result!.text).toContain("Project README");
    for (const chrome of ["Copilot Write better code", "Repository menu item", "Notifications", "Pricing", "© 2026 Example Inc.", "GitHub - example/project"]) {
      expect(result!.text).not.toContain(chrome);
    }
    expect(result!.text.length).toBeLessThan(1_600);
  });

  it("drops nav and footer when the page has no main region (F3, F8)", () => {
    const result = read(blogLike());
    expect(result!.text).toContain("Cache hit rate follows the order of the prompt");
    expect(result!.text).not.toContain("Topic archive");
    expect(result!.text).not.toContain("newsletter");
  });

  it("keeps docs content and drops sidebar navigation (F4)", () => {
    const result = read(docsLike());
    expect(result!.text).toContain("Set the connector scope to the numeric collection identifier");
    expect(result!.text).not.toContain("Sidebar page");
    expect(result!.text).not.toContain("Was this page helpful");
  });

  it("marks an app shell partial with its own reason (F5)", () => {
    const result = read('<html><head><title>App</title></head><body><div id="app"></div><script>Loading...</script></body></html>');
    expect(result!.quality).toBe("partial");
    expect(result!.reason).toContain("app shell");
  });

  it("marks low-yield extraction partial instead of claiming completeness (F6)", () => {
    const chrome = `<nav>${Array.from({ length: 40 }, (_, index) => `<a href="/x/${index}">Navigation entry number ${index}</a>`).join("")}</nav>`;
    const result = read(`<html><body>${chrome}<main><p>Hi.</p></main></body></html>`);
    expect(result!.quality).toBe("partial");
    expect(result!.reason).toMatch(/substantive/i);
  });

  it("keeps a genuinely short page complete (F7, F12)", () => {
    const short = read("<html><body><p>Hello world</p></body></html>");
    expect(short!.text).toBe("Hello world");
    expect(short!.quality).toBeUndefined();
    const json = extractReadableText(encode('{"a":1}'), "application/json", 100);
    expect(json!.text).toBe('{"a":1}');
    expect(json!.quality).toBeUndefined();
  });

  it("never leaks script, style or commented markup and never deletes later text (F9)", () => {
    const result = read("<html><body><script>if (a < b) { write(\"<div>nope</div>\") }</script><style>.a{color:red}</style><!-- <p>hidden</p> --><p>After script</p></body></html>");
    expect(result!.text).toBe("After script");
  });

  it("decodes entity-encoded text (F10)", () => {
    expect(read("<html><body><p>&lt;tag&gt; &amp; more</p></body></html>")!.text).toBe("<tag> & more");
  });

  it("reports truncation at the readable bound (F11)", () => {
    const result = read(`<html><body><p>${"a".repeat(500)}</p></body></html>`, 100);
    expect(result!.truncated).toBe(true);
    expect(result!.text).toHaveLength(100);
  });

  it("handles uppercase tags and a quoted attribute containing a bracket (F13)", () => {
    const result = read('<HTML><BODY><NAV><a href="/x">Menu</a></NAV><MAIN><a title="a > b">Real content sentence.</a></MAIN></BODY></HTML>');
    expect(result!.text).toBe("Real content sentence.");
  });

  it("keeps every card of a listing page rather than one region (F16)", () => {
    const cards = ["First card body sentence.", "Second card body sentence.", "Third card body sentence."].map(text => `<article><h2>${text.split(" ")[0]}</h2><p>${text}</p></article>`).join("");
    const result = read(`<html><body><header><a href="/">Site</a></header><main>${cards}</main></body></html>`);
    for (const sentence of ["First card body sentence.", "Second card body sentence.", "Third card body sentence."]) expect(result!.text).toContain(sentence);
  });

  it("does not let a tiny main element displace real body text (F17)", () => {
    const body = `<p>${"The real article text continues here. ".repeat(40)}</p>`;
    const result = read(`<html><body><main><a href="/">Home</a></main><div>${body}</div></body></html>`);
    expect(result!.text).toContain("The real article text continues here.");
    expect(result!.text).not.toContain("Home");
  });

  it("keeps text after malformed and unbalanced markup (F18)", () => {
    expect(read("<html><body><p>one<p>two<p>three")!.text).toBe("one two three");
  });

  it("stays bounded on a large document (F19)", () => {
    const section = `<section><h2>Heading</h2><p>${"Readable sentence. ".repeat(20)}</p></section>`;
    const started = Date.now();
    const result = read(`<html><body><main>${section.repeat(400)}</main></body></html>`, 5_000);
    expect(result!.text.length).toBe(5_000);
    expect(result!.truncated).toBe(true);
    expect(Date.now() - started).toBeLessThan(5_000);
  });
});
