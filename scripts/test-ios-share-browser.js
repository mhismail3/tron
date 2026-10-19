// Run with agent_browser.script after defining fixtureUrl (loopback only),
// artifactRoot (absolute screenshot directory), and phase: 'delivery-layout' or
// 'keyboard-zoom'. Independent phases fit the tool's 25-call bound. See tools/web/README.md.
// This drives real generated HTML; it never activates an installation link.
if (!/^http:\/\/127\.0\.0\.1:\d+\/$/.test(fixtureUrl)) throw new Error("Use an isolated loopback fixture, never the live host");
if (!["delivery-layout", "keyboard-zoom"].includes(phase)) throw new Error("Choose a documented test phase");
const checks = [];
let failure;
function check(value, behavior) {
  checks.push({ behavior, passed: Boolean(value) });
  if (!value) throw new Error(behavior);
}
async function command(args, stdin) {
  const result = await browser({ args, stdin });
  if (!result.ok) throw new Error(result.text || JSON.stringify(result));
  return result.data;
}
async function evaluate(source) { return (await command(["eval", "--stdin"], source)).result; }
try {
  await command(["open", fixtureUrl]);
  const snapshot = await command(["snapshot", "-i"]);
  if (phase === "delivery-layout") {
    const routes = await evaluate(`(async () => {
      const sections = [...document.querySelectorAll('main section')];
      if (!sections.length) throw new Error('No published builds');
      const latest = await (await fetch('/latest.plist')).text();
      const results = [];
      for (const [index, section] of sections.entries()) {
        const install = new URL(section.querySelector('a').href);
        if (install.protocol !== 'itms-services:' || install.searchParams.get('action') !== 'download-manifest') throw new Error('Broken install action');
        const manifestUrl = new URL(install.searchParams.get('url'));
        if (manifestUrl.protocol !== 'https:' || !/^\\/builds\\/[^/]+\\/manifest.plist$/.test(manifestUrl.pathname)) throw new Error('Broken HTTPS manifest route');
        const manifest = await fetch(manifestUrl.pathname);
        const xml = await manifest.text();
        if (!manifest.ok || manifest.headers.get('content-type') !== 'text/xml') throw new Error('Manifest delivery');
        if (index === 0 && xml !== latest) throw new Error('Latest no longer names first build');
        const asset = [...new DOMParser().parseFromString(xml, 'text/xml').querySelectorAll('key')].find(x => x.textContent === 'url')?.nextElementSibling?.textContent;
        const ipaUrl = new URL(asset);
        if (ipaUrl.origin !== manifestUrl.origin) throw new Error('IPA escaped manifest origin');
        const record = await (await fetch(manifestUrl.pathname.replace('manifest.plist', 'build.json'))).json();
        const ipa = await fetch(ipaUrl.pathname);
        const bytes = await ipa.arrayBuffer();
        const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x => x.toString(16).padStart(2, '0')).join('');
        if (!ipa.ok || digest !== record.sha256 || bytes.byteLength !== record.bytes) throw new Error('Download does not match metadata');
        if (section.querySelector('h2').textContent !== record.title || section.querySelector('.tron-reading').textContent !== record.notes) throw new Error('Rendered metadata differs from stored record');
        results.push({ id: record.id, bytes: bytes.byteLength });
      }
      const head = await fetch('/', { method: 'HEAD' });
      return { builds: results, noStore: head.headers.get('cache-control') === 'no-store', noListing: (await fetch('/builds/')).status === 404,
        inertMarkup: !document.querySelector('script, main img'), namedMain: !!document.querySelector('main h1'), lang: document.documentElement.lang,
        externalResources: performance.getEntriesByType('resource').filter(x => !x.name.startsWith(location.origin + '/')).length };
    })()`);
    check(routes.builds.length > 0 && routes.noStore && routes.noListing, "HTTP routes deliver every displayed manifest and matching IPA, latest, no-store and no listings");
    check(routes.inertMarkup && routes.externalResources === 0, "Generated page has no executable notes or external asset dependency");
    check(routes.namedMain && routes.lang === "en", "Page exposes a language, main landmark and heading");

    const layouts = [];
    for (const theme of ["light", "dark"]) {
      await command(["set", "media", theme]);
      for (const width of [1120, 390, 320]) {
        await command(["set", "viewport", String(width), "844"]);
        const layout = await evaluate(`(() => {
          const buttons = [...document.querySelectorAll('main a')];
          return { background: getComputedStyle(document.body).backgroundColor, noOverflow: document.documentElement.scrollWidth <= innerWidth,
            targets: buttons.every(x => { const r = x.getBoundingClientRect(); return r.width >= 44 && r.height >= 44 && x.textContent.trim(); }),
            unclipped: [...document.querySelectorAll('main p, main h2')].every(x => x.scrollHeight <= x.clientHeight + 1) };
        })()`);
        check(layout.noOverflow && layout.targets && layout.unclipped, `${theme} ${width}px: readable reflow, no clipped content and named 44px targets`);
        layouts.push({ theme, width, ...layout });
      }
      // Measure actual computed, composited text/background contrast, not CSS
      // literals. All reading surfaces are opaque; chrome alpha composites below.
      const contrast = await evaluate(`(() => {
        const rgb = value => value.match(/[\\d.]+/g).map(Number);
        const luminance = c => c.slice(0, 3).map(v => { v /= 255; return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }).reduce((s, v, i) => s + v * [.2126, .7152, .0722][i], 0);
        return [...document.querySelectorAll('h1, h2, .tron-meta, .tron-reading, .tron-badge, .tron-button')].map(el => {
          const layers = []; for (let p = el; p; p = p.parentElement) layers.unshift(rgb(getComputedStyle(p).backgroundColor));
          const background = layers.reduce((under, c) => { const a = c[3] ?? 1; return c.slice(0, 3).map((v, i) => v * a + under[i] * (1 - a)); }, [255, 255, 255]);
          const a = luminance(rgb(getComputedStyle(el).color)), b = luminance(background);
          return { text: el.textContent.slice(0, 40), ratio: (Math.max(a, b) + .05) / (Math.min(a, b) + .05) };
        });
      })()`);
      check(contrast.every(x => x.ratio >= 4.5), `${theme}: rendered text and button labels meet 4.5:1 contrast`);
      await command(["set", "viewport", "390", "844"]);
      await command(["screenshot", "--full", `${artifactRoot}/browser-${theme}.png`]);
    }
    check(layouts[0].background !== layouts[3].background, "Light/dark preference changes the rendered surface without a script");
    emit({ snapshot, routes, layouts });
  }
  if (phase === "keyboard-zoom") {
    await command(["set", "viewport", "390", "844"]);
    await command(["set", "media", "light", "reduced-motion"]);
    const buildCount = await evaluate('document.querySelectorAll("main section a").length');
    const focus = [];
    for (let i = 0; i < buildCount; i++) {
      await command(["press", "Tab"]);
      focus.push(await evaluate(`(() => { const x = document.activeElement, s = getComputedStyle(x), r = x.getBoundingClientRect(); return { href: x.href, text: x.textContent, visible: r.bottom > 0 && r.top < innerHeight, outlined: s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0 }; })()`));
    }
    check(buildCount > 0 && focus.every(x => x.href?.startsWith("itms-services:") && x.visible && x.outlined) && new Set(focus.map(x => x.href)).size === buildCount,
      "Keyboard Tab reaches every install link once with visible focus, without activating it");
    const large = await evaluate(`document.documentElement.style.fontSize="200%"; ({ noOverflow: document.documentElement.scrollWidth <= innerWidth,
      readable: [...document.querySelectorAll('main p, main h2')].every(x => x.scrollHeight <= x.clientHeight + 1),
      reduced: matchMedia('(prefers-reduced-motion: reduce)').matches,
      blurDisabled: getComputedStyle(document.querySelector('header')).backdropFilter === 'none' })`);
    check(large.noOverflow && large.readable && large.reduced && large.blurDisabled, "200% text reflows and reduced motion removes optional blur without hiding content");
    await command(["screenshot", "--full", `${artifactRoot}/browser-large-reduced.png`]);
    emit({ snapshot, focus, large });
  }
} catch (error) { failure = String(error); }
emit({ phase, passed: !failure && checks.length > 0, checks, failure, limitation: "Chrome fixture only; no install activation, physical Safari/VoiceOver or forced-colors/reduced-transparency emulation" });
