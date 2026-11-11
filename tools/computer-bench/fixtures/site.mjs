// Purpose: the computer-bench local fixture site: form controls, upload, download, tabs, dialogs, cookie session and a two-origin consent flow.
import { createServer } from "node:http";

const page = (title, body, script = "") => `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head><body>${body}${script ? `<script>${script}</script>` : ""}</body></html>`;

const FORM = page("Bench Form", `
<h1>Bench Form</h1>
<label>Name <input id="name" aria-label="Name" autocomplete="off"></label><br>
<label>Prefilled <input id="prefilled" aria-label="Prefilled" value="old value" autocomplete="off"></label><br>
<button id="inc" type="button">Increment</button> <span id="count">0</span><br>
<label>Flavor <select id="flavor" aria-label="Flavor"><option>vanilla</option><option>chocolate</option><option>strawberry</option></select></label>
<label><input id="agree" type="checkbox"> Agree</label><br>
<input id="file" type="file" aria-label="Upload"> <span id="fileinfo"></span><br>
<a id="dl" href="/download/bench.txt" download>Download</a>
<a id="newtab" href="/tab2.html" target="_blank">Open tab</a><br>
<button id="confirm" type="button">Confirm</button> <span id="dialogresult"></span>`,
`document.getElementById("inc").onclick=()=>{const c=document.getElementById("count");c.textContent=String(Number(c.textContent)+1)};
document.getElementById("file").onchange=(e)=>{const f=e.target.files[0];document.getElementById("fileinfo").textContent=f?f.name+":"+f.size:""};
document.getElementById("confirm").onclick=()=>{document.getElementById("dialogresult").textContent=confirm("Continue?")?"confirmed":"cancelled"};`);

export const DOWNLOAD_BODY = "tron-bench-download\n";

export function startSite() {
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://fixture");
    const html = (body, status = 200, headers = {}) => { response.writeHead(status, { "content-type": "text/html; charset=utf-8", ...headers }); response.end(body); };
    if (url.pathname === "/form.html") return html(FORM);
    if (url.pathname === "/tab2.html") return html(page("Bench Tab 2", "<h1>Second tab</h1>"));
    if (url.pathname === "/download/bench.txt") {
      response.writeHead(200, { "content-type": "text/plain", "content-disposition": "attachment; filename=bench.txt" });
      return response.end(DOWNLOAD_BODY);
    }
    if (url.pathname === "/login") return html(page("Bench Login", "<p id=\"result\">signed in</p>"), 200, { "set-cookie": "bench_session=bench-user; Max-Age=86400; Path=/; SameSite=Lax" });
    if (url.pathname === "/whoami") {
      const user = /(?:^|;\s*)bench_session=([^;]+)/.exec(request.headers.cookie ?? "")?.[1] ?? "anonymous";
      return html(page("Bench Whoami", `<p id="result">user=${user}</p>`));
    }
    if (url.pathname === "/oauth/authorize") {
      const redirect = url.searchParams.get("redirect_uri") ?? "", state = url.searchParams.get("state") ?? "";
      return html(page("Bench Consent", `<h1>Allow Bench App?</h1><form action="/oauth/approve" method="get">
<input type="hidden" name="redirect_uri" value="${encodeURI(redirect)}"><input type="hidden" name="state" value="${encodeURIComponent(state)}">
<button id="allow" type="submit">Allow</button> <button id="deny" type="button">Deny</button></form>`));
    }
    if (url.pathname === "/oauth/approve") {
      const target = new URL(url.searchParams.get("redirect_uri"));
      target.searchParams.set("code", "bench-code");
      target.searchParams.set("state", url.searchParams.get("state") ?? "");
      response.writeHead(302, { location: target.href });
      return response.end();
    }
    if (url.pathname === "/callback") return html(page("Bench Callback", `<p id="result">code=${url.searchParams.get("code")} state=${url.searchParams.get("state")}</p>`));
    response.writeHead(404);
    response.end();
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
    const port = server.address().port;
    resolve({ port, origin: `http://127.0.0.1:${port}`, altOrigin: `http://localhost:${port}`, close: () => new Promise((done) => { server.closeAllConnections(); server.close(done); }) });
  }));
}
