import { createServer, type Server } from "node:http";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join, extname } from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { webResearchTool, type WebResearchRequest } from "./web-research-contract.js";
import { WebResearch, type WebResearchTransport } from "./web-research.js";

/** Start once per Gateway, resolve the same service at every call and reload.
 * Child grants carry only a local scoped capability, never provider credentials. */
export function createWebResearchModule(transport: () => WebResearchTransport | undefined): ModuleDescriptor {
  return { name: "tron-web-research", purpose: "One bounded keyless public-web capability for Home, workers and native children.",
    tools: ["web_search"], commands: [], start: async host => {
      const service = new WebResearch(transport);
      const grants = new Map<string, { token: string; path: string }>();
      const tokens = new Map<string, string>();
      const childDirectory = join(host.tronHome, "gateway", "web-research-children");
      let directory: string | undefined;
      let server: Server | undefined;
      let opening: Promise<void> | undefined;
      const open = () => opening ??= (async () => {
        // Unix socket paths have a host limit; inherited fixture TMPDIRs can be much longer.
        directory = await mkdtemp(join("/tmp", "tron-web-")); await chmod(directory, 0o700);
        await mkdir(childDirectory, { recursive: true, mode: 0o700 });
        server = createServer((request, response) => {
          const scope = tokens.get((request.headers.authorization ?? "").replace(/^Bearer /u, ""));
          if (!scope || request.method !== "POST" || request.url !== "/") { response.writeHead(403).end(); request.resume(); return; }
          const controller = new AbortController();
          response.on("close", () => { if (!response.writableFinished) controller.abort(); });
          const chunks: Buffer[] = []; let bytes = 0;
          request.on("data", (chunk: Buffer) => { bytes += chunk.length; if (bytes > 8192) request.destroy(); else chunks.push(chunk); });
          request.on("end", () => {
            let input: WebResearchRequest;
            try { input = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { response.writeHead(400).end(); return; }
            void service.execute(scope, input, controller.signal).then(result => {
              if (!response.destroyed) response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(result));
            }).catch(() => { if (!response.destroyed) response.writeHead(503).end(); });
          });
        });
        server.requestTimeout = 15000; server.headersTimeout = 15000;
        await new Promise<void>((resolve, reject) => { server!.once("error", reject); server!.listen(join(directory!, "service.sock"), resolve); });
        await chmod(join(directory, "service.sock"), 0o600);
      })();
      const grant = async (scope: string) => {
        await open();
        let entry = grants.get(scope);
        if (!entry) {
          if (grants.size >= 4096) throw new Error("Shared web research child grant bound exceeded");
          const token = randomBytes(32).toString("hex");
          // Retained child launches carry an exact extension path. Reopening a
          // parent must recreate that path with the new runtime's socket grant.
          const path = join(childDirectory, `${createHash("sha256").update(scope).digest("hex")}.ts`);
          const child = fileURLToPath(new URL(`./web-research-child${extname(fileURLToPath(import.meta.url))}`, import.meta.url));
          await writeFile(path, `import { webResearchChild } from ${JSON.stringify(pathToFileURL(child).href)};\nexport default webResearchChild(${JSON.stringify(join(directory!, "service.sock"))}, ${JSON.stringify(token)});\n`, { mode: 0o600 });
          entry = { token, path }; grants.set(scope, entry); tokens.set(token, scope);
        }
        return entry;
      };
      const retire = async (scope: string) => {
        const entry = grants.get(scope); if (!entry) return;
        grants.delete(scope); tokens.delete(entry.token); await rm(entry.path, { force: true });
      };
      const stop = async () => {
        await opening?.catch(() => {});
        await service.stop();
        if (server) await new Promise<void>(resolve => { server!.close(() => resolve()); server!.closeAllConnections(); });
        await Promise.all([...grants.keys()].map(retire));
        if (directory) await rm(directory, { recursive: true, force: true });
        grants.clear(); tokens.clear();
      };
      return { stop, hooks: {
        kernelLifecycle: () => ({ initialize: async () => {}, started: () => {}, closing: () => {}, dispose: stop }),
      }, extension: session => pi => {
        pi.registerTool(webResearchTool((request, signal) => service.execute(session.sessionId(), request, signal)));
        let registration: { dispose(): void } | undefined;
        pi.on("session_start", async (_event, ctx) => {
          if (!session.requireChildExtensions) return;
          const entry = await grant(session.sessionId());
          registration = await session.requireChildExtensions(ctx.sessionManager.getSessionId(), [{ id: "tron-web-research", path: entry.path }]);
        });
        pi.on("session_shutdown", async () => { registration?.dispose(); registration = undefined; await retire(session.sessionId()); });
      } };
    } };
}
