import { spawnSync } from "node:child_process";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";

/**
 * Project-root resources lock (packages/gateway/docs/scenario-locks.md; K-0 §7 E0e follow-up)
 * for the two session-free `projectDir` call sites `project-root-trust` does not
 * reach: the package owner (`packages.list`, `admin/package-service.ts`) and the
 * session-free extension loader behind `hooks.list`
 * (`admin/session-free-extensions.ts`). Through the real Gateway with the
 * production owners (harness option `administrativeResources`), a phone lists
 * packages and hooks for a subdirectory of a Git project whose root and
 * subdirectory each configure a package and a project extension, before and
 * after trusting the project. Both reads resolve the subdirectory to the root's
 * Project layer: the root's package and extension, never the subdirectory's.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

function git(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
}

async function write(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

/** An extension with one tool and one event handler, named for its scope. */
const extension = (tool: string) => `
export default function (pi) {
  pi.registerTool({
    name: ${JSON.stringify(tool)}, label: ${JSON.stringify(tool)}, description: "Lock project resource",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }),
  });
  pi.on("tool_call", () => {});
}
`;

/** A local package that provides one extension. */
async function localPackage(directory: string, name: string, tool: string): Promise<void> {
  await write(join(directory, "package.json"), JSON.stringify({ name, version: "1.0.0", pi: { extensions: ["extensions"] } }));
  await write(join(directory, "extensions", `${name}.ts`), extension(tool));
}

describe("gateway/session-catalog project-root resources lock", () => {
  it("project-root-resources: packages and hooks listed for a subdirectory come from the project root", async () => {
    const gateway = await startLockGateway("project-root-resources", { administrativeResources: true });
    gateways.push(gateway);
    // Trust and the SDK name canonical paths; the temp root is a symlink on macOS.
    const root = await realpath(gateway.root);
    const project = join(root, "project");
    const nested = join(project, "packages", "app");
    await write(join(project, ".pi", "settings.json"), `${JSON.stringify({ packages: ["../vendor/root-package"] })}\n`);
    await localPackage(join(project, "vendor", "root-package"), "root-package", "root_package_tool");
    await write(join(project, ".pi", "extensions", "root-hooks.ts"), extension("root_project_tool"));
    await write(join(nested, ".pi", "settings.json"), `${JSON.stringify({ packages: ["../vendor/nested-package"] })}\n`);
    await localPackage(join(nested, "vendor", "nested-package"), "nested-package", "nested_package_tool");
    await write(join(nested, ".pi", "extensions", "nested-hooks.ts"), extension("nested_project_tool"));
    git(project, "init", "-q");

    const phone = await gateway.connect("phone");
    const packagesUntrusted = await phone.request("packages.list", { cwd: nested });
    const hooksUntrusted = await phone.request("hooks.list", { cwd: nested });
    const decided = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust the lock project",
      changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: nested } }],
    });
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    const packagesTrusted = await phone.request("packages.list", { cwd: nested });
    const hooksTrusted = await phone.request("hooks.list", { cwd: nested });
    const hooksGlobal = await phone.request("hooks.list", {});

    const recorded = gateway.record();
    const trace = {
      lock: "project-root-resources",
      // Responses are recorded once, under `observed`.
      requests: recorded.exchanges.map((entry) => { const { response: _response, ...request } = entry as Record<string, TraceValue>; return request; }),
      // The hook inventory's encoded size counts the host's temp paths, so it is blinded.
      observed: normalizeTraceValue(JSON.parse(JSON.stringify({ packagesUntrusted, hooksUntrusted, packagesTrusted, hooksTrusted, hooksGlobal }),
        (key, value: unknown) => key === "encodedBytes" ? "<bytes>" : value) as TraceValue, gateway.normalization),
    };
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED["project-root-resources"]);
    for (const response of [packagesUntrusted, hooksUntrusted, packagesTrusted, hooksTrusted, hooksGlobal]) {
      expect(response.ok, JSON.stringify(response)).toBe(true);
    }
    const packages = JSON.stringify(packagesTrusted.result);
    expect(packages).toContain("root-package");
    expect(packages).toContain("root_package_tool");
    expect(packages).not.toContain("nested-package");
    const hooks = JSON.stringify(hooksTrusted.result);
    expect(hooks).toContain("root-hooks.ts");
    expect(hooks).toContain("root-package");
    expect(hooks).not.toContain("nested");
    expect(JSON.stringify(hooksUntrusted.result)).not.toContain("root-hooks.ts");
    expect(JSON.stringify(hooksGlobal.result)).not.toContain("root-hooks.ts");
  }, 60_000);
});

/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): the scenario's normalized trace without event schemas, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "project-root-resources": {
    "lock": "project-root-resources",
    "requests": [
      {
        "client": "phone",
        "method": "packages.list",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        }
      },
      {
        "client": "phone",
        "method": "hooks.list",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        }
      },
      {
        "client": "phone",
        "method": "settings.change",
        "params": {
          "changes": [
            {
              "key": "permissions.projectTrust",
              "layer": "global",
              "op": "set",
              "qualifiers": {
                "project": "<tmp>/project/packages/app"
              },
              "value": true
            }
          ],
          "commandId": "lock-command-0001",
          "reason": "Trust the lock project",
          "target": {
            "kind": "global"
          }
        }
      },
      {
        "client": "phone",
        "method": "packages.list",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        }
      },
      {
        "client": "phone",
        "method": "hooks.list",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        }
      },
      {
        "client": "phone",
        "method": "hooks.list",
        "params": {}
      }
    ],
    "observed": {
      "hooksGlobal": {
        "id": "<id>",
        "ok": true,
        "result": {
          "extensionLoadErrors": [],
          "extensionLoadWarnings": [],
          "extensions": [
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:codemode",
              "origin": "top-level",
              "path": "builtin:codemode",
              "resolvedPath": "builtin:codemode",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "codemode"
              ]
            },
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:tool-search",
              "origin": "top-level",
              "path": "builtin:tool-search",
              "resolvedPath": "builtin:tool-search",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "tool_search"
              ]
            },
            {
              "commands": [
                "mcp"
              ],
              "handlers": [
                {
                  "count": 1,
                  "event": "session_start"
                },
                {
                  "count": 1,
                  "event": "before_agent_start"
                },
                {
                  "count": 1,
                  "event": "tool_call"
                },
                {
                  "count": 1,
                  "event": "turn_start"
                },
                {
                  "count": 1,
                  "event": "mcp_servers_change"
                },
                {
                  "count": 1,
                  "event": "session_shutdown"
                }
              ],
              "name": "builtin:mcp",
              "origin": "top-level",
              "path": "builtin:mcp",
              "resolvedPath": "builtin:mcp",
              "scope": "temporary",
              "source": "builtin",
              "tools": []
            }
          ],
          "hookInventory": {
            "encodedBytes": "<bytes>",
            "encodedBytesLimit": 262144,
            "extensions": {
              "omitted": 0,
              "retained": 3,
              "total": 3
            },
            "handlerEvents": {
              "omitted": 0,
              "retained": 6,
              "total": 6
            },
            "loadErrors": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "loadWarnings": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "textFieldsOmitted": 0
          }
        },
        "type": "response"
      },
      "hooksTrusted": {
        "id": "<id>",
        "ok": true,
        "result": {
          "extensionLoadErrors": [],
          "extensionLoadWarnings": [],
          "extensions": [
            {
              "commands": [],
              "handlers": [
                {
                  "count": 1,
                  "event": "tool_call"
                }
              ],
              "name": "root-hooks.ts",
              "origin": "top-level",
              "path": "<tmp>/project/.pi/extensions/root-hooks.ts",
              "resolvedPath": "<tmp>/project/.pi/extensions/root-hooks.ts",
              "scope": "project",
              "source": "auto",
              "tools": [
                "root_project_tool"
              ]
            },
            {
              "commands": [],
              "handlers": [
                {
                  "count": 1,
                  "event": "tool_call"
                }
              ],
              "name": "root-package.ts",
              "origin": "package",
              "path": "<tmp>/project/vendor/root-package/extensions/root-package.ts",
              "resolvedPath": "<tmp>/project/vendor/root-package/extensions/root-package.ts",
              "scope": "project",
              "source": "../vendor/root-package",
              "tools": [
                "root_package_tool"
              ]
            },
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:codemode",
              "origin": "top-level",
              "path": "builtin:codemode",
              "resolvedPath": "builtin:codemode",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "codemode"
              ]
            },
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:tool-search",
              "origin": "top-level",
              "path": "builtin:tool-search",
              "resolvedPath": "builtin:tool-search",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "tool_search"
              ]
            },
            {
              "commands": [
                "mcp"
              ],
              "handlers": [
                {
                  "count": 1,
                  "event": "session_start"
                },
                {
                  "count": 1,
                  "event": "before_agent_start"
                },
                {
                  "count": 1,
                  "event": "tool_call"
                },
                {
                  "count": 1,
                  "event": "turn_start"
                },
                {
                  "count": 1,
                  "event": "mcp_servers_change"
                },
                {
                  "count": 1,
                  "event": "session_shutdown"
                }
              ],
              "name": "builtin:mcp",
              "origin": "top-level",
              "path": "builtin:mcp",
              "resolvedPath": "builtin:mcp",
              "scope": "temporary",
              "source": "builtin",
              "tools": []
            }
          ],
          "hookInventory": {
            "encodedBytes": "<bytes>",
            "encodedBytesLimit": 262144,
            "extensions": {
              "omitted": 0,
              "retained": 5,
              "total": 5
            },
            "handlerEvents": {
              "omitted": 0,
              "retained": 8,
              "total": 8
            },
            "loadErrors": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "loadWarnings": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "textFieldsOmitted": 0
          }
        },
        "type": "response"
      },
      "hooksUntrusted": {
        "id": "<id>",
        "ok": true,
        "result": {
          "extensionLoadErrors": [],
          "extensionLoadWarnings": [],
          "extensions": [
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:codemode",
              "origin": "top-level",
              "path": "builtin:codemode",
              "resolvedPath": "builtin:codemode",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "codemode"
              ]
            },
            {
              "commands": [],
              "handlers": [],
              "name": "builtin:tool-search",
              "origin": "top-level",
              "path": "builtin:tool-search",
              "resolvedPath": "builtin:tool-search",
              "scope": "temporary",
              "source": "builtin",
              "tools": [
                "tool_search"
              ]
            },
            {
              "commands": [
                "mcp"
              ],
              "handlers": [
                {
                  "count": 1,
                  "event": "session_start"
                },
                {
                  "count": 1,
                  "event": "before_agent_start"
                },
                {
                  "count": 1,
                  "event": "tool_call"
                },
                {
                  "count": 1,
                  "event": "turn_start"
                },
                {
                  "count": 1,
                  "event": "mcp_servers_change"
                },
                {
                  "count": 1,
                  "event": "session_shutdown"
                }
              ],
              "name": "builtin:mcp",
              "origin": "top-level",
              "path": "builtin:mcp",
              "resolvedPath": "builtin:mcp",
              "scope": "temporary",
              "source": "builtin",
              "tools": []
            }
          ],
          "hookInventory": {
            "encodedBytes": "<bytes>",
            "encodedBytesLimit": 262144,
            "extensions": {
              "omitted": 0,
              "retained": 3,
              "total": 3
            },
            "handlerEvents": {
              "omitted": 0,
              "retained": 6,
              "total": 6
            },
            "loadErrors": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "loadWarnings": {
              "omitted": 0,
              "retained": 0,
              "total": 0
            },
            "textFieldsOmitted": 0
          }
        },
        "type": "response"
      },
      "packagesTrusted": {
        "id": "<id>",
        "ok": true,
        "result": {
          "packages": [
            {
              "filtered": false,
              "installedPath": "<tmp>/project/vendor/root-package",
              "provides": {
                "commands": [],
                "prompts": [],
                "skills": [],
                "subagents": [],
                "themes": [],
                "tools": [
                  "root_package_tool"
                ]
              },
              "scope": "project",
              "source": "../vendor/root-package"
            }
          ],
          "providesDiagnostic": "subagent catalog unavailable: managed pi-subagents is not installed",
          "resources": {
            "extensions": [
              {
                "enabled": true,
                "metadata": {
                  "baseDir": "<tmp>/project/.pi",
                  "origin": "top-level",
                  "scope": "project",
                  "source": "auto"
                },
                "path": "<tmp>/project/.pi/extensions/root-hooks.ts"
              },
              {
                "enabled": true,
                "metadata": {
                  "baseDir": "<tmp>/project/vendor/root-package",
                  "origin": "package",
                  "packageRoot": "<tmp>/project/vendor/root-package",
                  "scope": "project",
                  "source": "../vendor/root-package"
                },
                "path": "<tmp>/project/vendor/root-package/extensions/root-package.ts"
              }
            ],
            "prompts": [],
            "skills": [],
            "themes": []
          }
        },
        "type": "response"
      },
      "packagesUntrusted": {
        "id": "<id>",
        "ok": true,
        "result": {
          "packages": [],
          "providesDiagnostic": "subagent catalog unavailable: managed pi-subagents is not installed",
          "resources": {
            "extensions": [],
            "prompts": [],
            "skills": [],
            "themes": []
          }
        },
        "type": "response"
      }
    }
  },
};
