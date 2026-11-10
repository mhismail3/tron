import { describe, expect, it } from "vitest";
import { ORDINARY_SESSION_PROFILE } from "./session-profile.js";
import { ModuleHost, type KernelHooks, type ModuleDescriptor, type ModuleInstance } from "./module-host.js";

const log = { log: () => {} };

function descriptor<C = void>(name: string, start: ModuleDescriptor<C>["start"], dependsOn?: ModuleDescriptor<unknown>[]): ModuleDescriptor<C> {
  return { name, purpose: name, tools: [], commands: [], ...(dependsOn ? { dependsOn } : {}), start };
}

describe("kernel/host module host", () => {
  it("starts in order, gates contracts by dependsOn and stops in reverse", async () => {
    const events: string[] = [];
    const tracked = <C>(name: string, instance: ModuleInstance<C>): ModuleInstance<C> => {
      events.push(`start ${name}`);
      return { ...instance, stop: async () => { events.push(`stop ${name}`); if (name === "b") throw new Error("b failed to stop"); } };
    };
    const a = descriptor<{ value: number }>("a", () => tracked("a", { contract: { value: 7 } }));
    const b = descriptor<void>("b", (host) => { events.push(`b read ${host.contract(a).value}`); return tracked("b", {}); }, [a as ModuleDescriptor<unknown>]);
    const c = descriptor<void>("c", () => tracked("c", {}));
    const host = await ModuleHost.start([a, b, c] as ModuleDescriptor<unknown>[], { tronHome: "/unused", log }, []);
    expect(host.contract(a)).toEqual({ value: 7 });
    await expect(host.stop()).rejects.toThrow("One or more modules failed to stop");
    expect(events).toEqual(["start a", "b read 7", "start b", "start c", "stop c", "stop b", "stop a"]);

    const undeclared = descriptor<void>("undeclared", (gateway) => { gateway.contract(a); return {}; });
    await expect(ModuleHost.start([a, undeclared] as ModuleDescriptor<unknown>[], { tronHome: "/unused", log }, []))
      .rejects.toThrow("Module undeclared does not declare a in dependsOn");
    const early = descriptor<void>("early", (gateway) => { gateway.contract(a); return {}; }, [a as ModuleDescriptor<unknown>]);
    await expect(ModuleHost.start([early, a] as ModuleDescriptor<unknown>[], { tronHome: "/unused", log }, []))
      .rejects.toThrow("Module a is not started before early");
  });

  it("refuses composition errors at start and stops what already started", async () => {
    const stopped: string[] = [];
    const modelUsed = (name: string) => descriptor<void>(name, () => ({
      hooks: { modelUsed: () => name } as Partial<KernelHooks>, stop: async () => { stopped.push(name); },
    }));
    await expect(ModuleHost.start([modelUsed("first"), modelUsed("second")], { tronHome: "/unused", log }, []))
      .rejects.toThrow("Policy hook modelUsed is implemented by both first and second");
    expect(stopped).toEqual(["second", "first"]);

    const unknown = descriptor<void>("unknown", () => ({ hooks: { notAHook: () => {} } as unknown as Partial<KernelHooks> }));
    await expect(ModuleHost.start([unknown], { tronHome: "/unused", log }, [])).rejects.toThrow("implements unknown hook notAHook");
    const serves = (name: string) => descriptor<void>(name, () => ({ rpc: { "x.read": { kind: "read", handle: async () => name } } }));
    await expect(ModuleHost.start([serves("one"), serves("two")], { tronHome: "/unused", log }, [])).rejects.toThrow("RPC x.read is served by both one and two");
    const failing = descriptor<void>("failing", () => { throw new Error("start failed"); });
    stopped.length = 0;
    await expect(ModuleHost.start([modelUsed("kept"), failing], { tronHome: "/unused", log }, [])).rejects.toThrow("start failed");
    expect(stopped).toEqual(["kept"]);
  });

  it("admits unique profile recipes by identity and rejects reserved/duplicate names with joined startup cleanup", async () => {
    const recipe = { ...ORDINARY_SESSION_PROFILE, name: "named" };
    const host = await ModuleHost.start([descriptor("owner", () => ({ profiles: [recipe] }))], { tronHome: "/unused", log }, []);
    try {
      Reflect.set(recipe, "name", "renamed");
      expect(host.profile("named")).toBe(recipe);
      expect(host.profile("ordinary")).toBe(ORDINARY_SESSION_PROFILE);
      expect(() => host.profile("missing")).toThrow();
    } finally { await host.stop(); }
    for (const name of ["named", "ordinary", "unrecorded"]) {
      const stopped: string[] = [];
      const owns = (module: string, profiles: ModuleInstance["profiles"]) => descriptor(module, () => ({
        profiles, stop: async () => { stopped.push(module); },
      }));
      await expect(ModuleHost.start([owns("first", [recipe]), owns("second", [{ ...recipe, name }])], { tronHome: "/unused", log }, []))
        .rejects.toThrow(`Profile ${name} is already registered`);
      expect(stopped).toEqual(["second", "first"]);
    }
  });

  it("dispatches hooks, RPCs and capabilities as they stand at each call", async () => {
    const instances: ModuleInstance[] = [];
    const observer = (name: string) => descriptor<void>(name, () => {
      const instance: ModuleInstance = {
        hooks: { sessionRetired: () => name } as Partial<KernelHooks>,
        capabilities: [`${name}.v1`],
        rpc: { [`${name}.read`]: { kind: "read", handle: async () => name } },
      };
      instances.push(instance);
      return instance;
    });
    const host = await ModuleHost.start([observer("first"), observer("second")], { tronHome: "/unused", log }, []);
    const retired = () => host.observers("sessionRetired").map(hook => (hook as () => string)());
    expect(retired()).toEqual(["first", "second"]);
    expect(host.capabilities()).toEqual(["first.v1", "second.v1"]);
    expect(await host.rpc("second.read")?.handle({}, { identity: "module-host-fixture" })).toBe("second");
    expect(host.rpc("toString")).toBeUndefined();
    expect(host.policy("modelUsed")).toBeUndefined();
    instances[0]!.hooks = { sessionRetired: () => "first, replaced", modelUsed: () => "late" } as Partial<KernelHooks>;
    expect(retired()).toEqual(["first, replaced", "second"]);
    expect((host.policy("modelUsed") as () => string)()).toBe("late");
  });
});
