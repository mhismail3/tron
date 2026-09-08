import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";
import { attributeExtensions } from "../extensions/owner-attribution.js";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { createTronDisplayExtension } from "./tron-display-extension.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true }))); });

describe("browser live public SDK load boundary", () => {
  it.each([true, false])("uses finalized package provenance, not provisional metadata (trusted=%s)", async (trusted) => {
    const root = await mkdtemp(join(tmpdir(), "tron-browser-loader-")); roots.push(root);
    const cwd = join(root, "project"), agentDir = join(root, "agent");
    const packageRoot = join(agentDir, "git/github.com/fitchmultz/pi-agent-browser-native");
    await mkdir(cwd); await mkdir(packageRoot, { recursive: true });
    // Synthetic package exercises the actual public loader ordering. Installed
    // compiled-provider/browser execution is a separate retained qualification.
    await writeFile(join(packageRoot, "package.json"), JSON.stringify({ name: "fixture", type: "module", pi: { extensions: ["index.js"] } }));
    await writeFile(join(packageRoot, "index.js"), `export default function (pi) {
      pi.registerTool({name:'agent_browser',label:'Fixture',description:'Fixture',parameters:{type:'object',properties:{}},
      execute:async()=>({content:[],isError:false,details:{command:'get',subcommand:'cdp-url',exitCode:0,resultCategory:'success',agentBrowserStarted:true,sessionName:'fixture',data:{cdpUrl:'ws://127.0.0.1:1234/devtools/browser/12345678-1234-1234-1234-123456789abc'}}})});
    }`);
    const views = new BrowserLiveViewRegistry(() => { throw new Error("Registration must not connect"); });
    const source = trusted ? "git:github.com/fitchmultz/pi-agent-browser-native" : packageRoot;
    const provisional: string[] = [];
    const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager: SettingsManager.inMemory({ packages: [source] }),
      noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
      extensionFactories: [{ name: "tron-display", factory: createTronDisplayExtension({
        sessionId: () => "session", cwd: () => cwd, artifacts: {} as never, liveViews: views,
      }) }],
      extensionsOverride(base) {
        provisional.push(...base.extensions.filter((extension) => extension.tools.has("agent_browser")).map((extension) => extension.sourceInfo.source));
        return attributeExtensions(base, { views, sessionId: "session", runtimeGeneration: "runtime" });
      },
    });
    try {
      await loader.reload();
      const result = loader.getExtensions();
      expect(result.errors).toEqual([]);
      expect(provisional).toEqual(["local"]);
      expect(result.extensions[0]?.sourceInfo.source).toBe(source);
      const tool = result.extensions[0]!.tools.get("agent_browser")!;
      const executed = await tool.definition.execute("call", {}, undefined, undefined, {} as never);
      const descriptor = (executed.details as any).browserLiveView;
      if (trusted) {
        expect(descriptor?.viewId).toEqual(expect.any(String));
        expect(views.describe("session", descriptor.viewId, descriptor.generation)).toEqual(descriptor);
        expect(Object.keys(descriptor).sort()).toEqual(["fallbackText", "generation", "schema", "title", "viewId"]);
        const text = executed.content.find((part) => part.type === "text" && part.text.includes('"browser_live"'));
        expect(text?.type).toBe("text");
        const source = JSON.parse((text as { text: string }).text.slice((text as { text: string }).text.indexOf("{")));
        const display = result.extensions.find((extension) => extension.tools.has("display"))!.tools.get("display")!;
        const displayed = await display.definition.execute("display", { title: "Browser", altText: "Browser", source }, undefined, undefined, {} as never);
        expect((displayed.details as any).display).toMatchObject({ kind: "browser_live", liveView: descriptor });
      } else expect(descriptor).toBeUndefined();
    } finally { views.dispose(); }
  });
});
