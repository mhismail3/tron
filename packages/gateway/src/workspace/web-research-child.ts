import { request } from "node:http";
import type { ExtensionFactory } from "../kernel/pi/coding-agent.js";
import { webResearchTool, type WebResearchRequest, type WebToolResult } from "./web-research-contract.js";

/** Child half of the Gateway-owned service. No provider keys, subscriptions or
 * independent quota/store owner exist in a child process. */
export function webResearchChild(socketPath: string, token: string): ExtensionFactory {
  return pi => {
    pi.registerTool(webResearchTool((input: WebResearchRequest, signal?: AbortSignal) => new Promise<WebToolResult>((resolve, reject) => {
      const body = JSON.stringify(input);
      const req = request({ socketPath, path: "/", method: "POST", headers: {
        authorization: `Bearer ${token}`, "content-type": "application/json", "content-length": Buffer.byteLength(body),
      }, signal, timeout: 15000 }, response => {
        const chunks: Buffer[] = []; let bytes = 0;
        response.on("data", (chunk: Buffer) => { bytes += chunk.length; if (bytes > 20000) response.destroy(new Error("Web research response exceeds its bound")); else chunks.push(chunk); });
        response.on("error", reject);
        response.on("end", () => {
          if (response.statusCode !== 200) { reject(new Error("Shared web research capability is unavailable")); return; }
          try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch { reject(new Error("Shared web research response is invalid")); }
        });
      });
      req.on("timeout", () => req.destroy(new Error("Shared web research deadline exceeded")));
      req.on("error", reject); req.end(body);
    })));
    pi.on("session_start", () => {
      const legacy = pi.getAllTools().filter(tool => ["fetch_content", "get_search_content", "source_check", "web_fetch"].includes(tool.name));
      if (legacy.length) throw new Error("Shared web research refuses a divergent legacy provider. Select extensions: [] for this child; the host-required web_search remains available.");
    });
  };
}
