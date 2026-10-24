#!/usr/bin/env python3
"""CLI journeys for `scripts/tron docs` (tools/docs/README.md).

1. The real repository: the module map lists exactly the ids that
   `git ls-files '*.module.json'` derives; the RPC list holds every method the
   recorded protocol wire lock exercised against a real Gateway; the settings list
   holds the key the recorded settings lock resolved, with the layers it edited;
   committed generated blocks are current.
2. A disposable fixture repository (the real `scripts/tron`, `scripts/tron-node`,
   `tools/docs` and `tools/ownership`, isolated HOME and Git): each generator reads
   its source (manifests, README Signals tables, the `invoke` switch, the settings
   schema), and a committed block goes stale, fails `check`, and `update` repairs it
   when a manifest is deleted or a settings key is added.

The last run's output is kept in `test-results/docs-cli/` for review.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "docs-cli"
TOOL_FILES = ("scripts/tron", "scripts/tron-node", ".node-version", "tools/docs/docs.py",
              "tools/docs/settings-keys.mjs", "tools/ownership/ownership.py")
NODE = subprocess.run([str(ROOT / "scripts/tron-node")], stdout=subprocess.PIPE, text=True, check=True).stdout.strip()


def run(cwd: Path, env: dict, *args: str) -> subprocess.CompletedProcess:
    result = subprocess.run([str(cwd / "scripts/tron"), "docs", *args], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with (ARTIFACTS / "last-run.txt").open("a") as log:
        log.write(f"$ ({cwd.name}) scripts/tron docs {' '.join(args)}\nexit {result.returncode}\n"
                  f"{result.stdout}{result.stderr}\n")
    return result


def first_cells(output: str) -> list[str]:
    return [line.split(" | ")[0][2:] for line in output.splitlines() if line.startswith("| `")]


class RealRepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if (ARTIFACTS / "last-run.txt").exists():
            (ARTIFACTS / "last-run.txt").unlink()

    def generate(self, *args: str) -> str:
        result = run(ROOT, dict(os.environ), *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_module_map_equals_tracked_manifests(self) -> None:
        manifests = subprocess.run(["git", "ls-files", "*.module.json"], cwd=ROOT, text=True,
                                   stdout=subprocess.PIPE, check=True).stdout.split()
        expected = set()
        for path in manifests:
            parts = path.split("/")
            expected.add(f"{parts[1] if parts[0] == 'packages' and len(parts) > 2 else 'repo'}/{parts[-1][:-12]}")
        self.assertEqual({cell.strip("`") for cell in first_cells(self.generate("modules"))}, expected)
        gateway = {cell.strip("`") for cell in first_cells(self.generate("modules", "packages/gateway"))}
        self.assertEqual(gateway, {m for m in expected if m.startswith("gateway/")})

    def test_rpc_list_holds_every_method_a_real_gateway_answered(self) -> None:
        lock = json.loads((ROOT / "packages/gateway/src/protocol/locks/protocol-wire.golden.json").read_text())
        answered = {call["method"] for call in lock["methods"] if call["ok"]}
        output = self.generate("rpc")
        rows = [line.split(" | ")[1] for line in output.splitlines() if line.startswith("| `")]
        listed = {name for row in rows for name in re.findall(r"`([^`]+)`", row)}
        self.assertTrue(answered, "the wire lock recorded no answered method")
        self.assertLessEqual(answered, listed)
        self.assertEqual(int(output.split(" ", 1)[0]), len(listed))

    def test_settings_list_holds_the_key_the_settings_lock_edited(self) -> None:
        lock = json.loads((ROOT / "packages/gateway/src/admin/locks/admin-settings-change.golden.json").read_text())
        resolved = next(e for e in lock["exchanges"] if e["method"] == "settings.resolve")["response"]["result"]["keys"][0]
        row = next(line for line in self.generate("settings").splitlines() if line.startswith(f"| `{resolved['key']}` |"))
        layers = row.split(" | ")[3].split(", ")
        self.assertLessEqual(set(resolved["presentation"]["editableLayers"]), set(layers))
        self.assertEqual(row.split(" | ")[2], resolved["group"])

    def test_signals_print_and_committed_blocks_are_current(self) -> None:
        # Today no module README has a Signals section and no doc embeds a block; consumers (#1501, #1497,
        # #1498) add them, and this then checks the real ones. The fixture cases prove both mechanisms.
        self.assertTrue(self.generate("signals").strip())
        self.assertRegex(self.generate("check"), r"^docs: \d+ generated block\(s\), current\n$")


class FixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-docs-")
        base = Path(self.temp.name)
        self.repo = base / "repo"
        (base / "home").mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(base / "home"), "TMPDIR": str(base),
                    "TRON_NODE_BIN": NODE, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        for relative in TOOL_FILES:
            self.write(relative, (ROOT / relative).read_text())
            shutil.copymode(ROOT / relative, self.repo / relative)
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [*TOOL_FILES, "tooling.module.json"]}))
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, relative: str, content: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content))

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True, stdout=subprocess.PIPE)

    def docs(self, *args: str, code: int = 0) -> str:
        self.git("add", "-A")
        result = run(self.repo, self.env, *args)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout

    def module(self, folder: str, name: str, files: dict) -> None:
        for relative, content in files.items():
            self.write(f"{folder}/{relative}", content)
        self.write(f"{folder}/{name}.module.json",
                   json.dumps({"layer": "L3", "owns": [*files, f"{name}.module.json"]}))

    def test_module_map_and_a_deleted_manifest_make_the_block_stale(self) -> None:
        self.module("packages/gw/src/a", "alpha", {"a.ts": "x\n", "README.md": "# Alpha\n"})
        self.module("packages/gw/src/b", "beta", {"b.ts": "x\n"})
        self.write("index.md", "# Index\n\n<!-- tron docs modules packages/gw -->\n<!-- /tron docs -->\n")
        self.write("root.module.json", json.dumps({"layer": "L5", "owns": ["index.md", "root.module.json"]}))
        self.assertIn("stale; run scripts/tron docs update", self.docs("check", code=1))
        self.assertIn("updated `tron docs modules packages/gw` in index.md", self.docs("update"))
        self.assertEqual(self.docs("check"), "docs: 1 generated block(s), current\n")
        index = (self.repo / "index.md").read_text()
        self.assertIn("| `gw/alpha` | L3 | 3 | `packages/gw/src/a/alpha.module.json` | `packages/gw/src/a/README.md` |", index)
        self.assertIn("| `gw/beta` | L3 | 2 | `packages/gw/src/b/beta.module.json` | — |", index)
        self.assertEqual(first_cells(self.docs("modules")), ["`gw/alpha`", "`gw/beta`", "`repo/root`", "`repo/tooling`"])

        # Known bad: a deleted manifest changes the map, so the committed block is stale.
        self.git("rm", "-q", "--cached", "packages/gw/src/b/beta.module.json")
        (self.repo / "packages/gw/src/b/beta.module.json").unlink()
        self.assertEqual(first_cells(self.docs("modules", "packages/gw")), ["`gw/alpha`"])
        self.assertIn("index.md: `tron docs modules packages/gw` is stale", self.docs("check", code=1))
        self.docs("update")
        self.assertNotIn("gw/beta", (self.repo / "index.md").read_text())
        self.docs("check")

    def test_signals_come_from_readme_signals_tables_only(self) -> None:
        self.module("svc", "svc", {"README.md": """\
            # Svc

            | Not | a signal |
            | --- | --- |
            | `table.outside` | x |

            ## Signals

            | Signal | Meaning |
            | --- | --- |
            | `svc.started` | first record |
            | `svc.failed` \\| `svc.retry` | escaped pipe |

            ```text
            | `in.a.fence` | no |
            ```

            ### Slow paths

            | Event | Level |
            |:--|--|
            | `svc.slow` | warning |

            ## Verify

            | `after.section` | no |
            """, "NOTES.md": "## Signals\n\n| Signal |\n| --- |\n| `not.a.readme` |\n"})
        self.module("other", "other", {"README.md": "## Signals\n\n| Signal | Meaning |\n| --- | --- |\n| `other.a` | x |\n"})
        self.assertEqual(self.docs("signals").splitlines(), [
            "| Event | Level | Module |", "| --- | --- | --- |",
            "| `svc.slow` | warning | [`repo/svc`](svc/README.md#signals) |",
            "",
            "| Signal | Meaning | Module |", "| --- | --- | --- |",
            "| `other.a` | x | [`repo/other`](other/README.md#signals) |",
            "| `svc.failed` \\| `svc.retry` | escaped pipe | [`repo/svc`](svc/README.md#signals) |",
            "| `svc.started` | first record | [`repo/svc`](svc/README.md#signals) |",
        ])

    def test_rpc_list_is_the_invoke_switch(self) -> None:
        self.module("packages/gateway/src/transport", "transport", {"gateway-service.ts": """\
            export class GatewayService {
              other(kind: string) {
                switch (kind) {
                  case "not.an.rpc": return 1;
                }
              }

              async invoke(client: unknown, method: string, rawParams: unknown): Promise<unknown> {
                switch (method) {
                  case "system.info":
                    return {};
                  case "session.create": {
                    switch (rawParams) {
                      case "nested.label": return 2;
                    }
                    return 3;
                  }
                  case "session.prompt":
                  default:
                    throw new Error(method);
                }
              }

              after(method: string) {
                switch (method) {
                  case "after.invoke": return 4;
                }
              }
            }
            """})
        output = self.docs("rpc")
        self.assertTrue(output.startswith("3 methods, registered in"))
        self.assertEqual(output.splitlines()[4:], ["| `session` | `session.create`, `session.prompt` |",
                                                   "| `system` | `system.info` |"])

    def test_settings_list_loads_the_schema_and_a_new_key_makes_the_block_stale(self) -> None:
        types = """\
            export const LAYERS = ["chat", "profile", "project", "mac", "builtin"] as const;
            export type LayerId = typeof LAYERS[number];
            """
        schema = """\
            import { LAYERS, type LayerId } from "../kernel/settings/tool-contract.js";
            const both = (path: string) => ({ project: path, mac: path });
            const ROLES = ["worker", "background"] as const;
            export const KEYS: readonly { id: string; layers: Partial<Record<LayerId, string>> }[] = [
              { id: "run.retry.maxRetries", group: "advanced", qualifier: "model", layers: { mac: "r", chat: "r" }, timing: "live",
                effect: "next-request", floor: "quiet", direction: () => "narrow" },
              ...ROLES.map(role => ({ id: `model.queue[role=${role}]`, group: "workers", home: { layers: [] },
                layers: both("q"), timing: { narrow: "live", widen: "fixed" }, floor: { widen: "notify", narrow: "quiet" } })),
            ];
            export const RECORD_SUBJECTS = [{ id: "tools.mcp.server", group: "tools", qualifier: "server", floor: "notify" }];
            void LAYERS;
            """
        self.module("packages/gateway/src/admin", "admin", {"settings-schema.ts": schema})
        self.module("packages/gateway/src/kernel/settings", "settings", {"tool-contract.ts": types})
        self.module("packages/gateway/src/main", "main", {"settings-schema.ts": """\
            import { KEYS, RECORD_SUBJECTS } from "../admin/settings-schema.js";
            export function createGatewaySettingsSchema() { return { KEYS, RECORD_SUBJECTS }; }
            """})
        self.write("settings.md", "<!-- tron docs settings -->\n<!-- /tron docs -->\n")
        self.write("root.module.json", json.dumps({"layer": "L5", "owns": ["settings.md", "root.module.json"]}))
        self.docs("update")
        self.assertEqual((self.repo / "settings.md").read_text().splitlines()[4:8], [
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
            "| `run.retry.maxRetries` | model | advanced | chat, mac | as allowed | live | next-request | quiet |",
            "| `model.queue[role=worker]` | — | workers | project, mac | none | narrow live, widen fixed | — | narrow quiet, widen notify |",
            "| `model.queue[role=background]` | — | workers | project, mac | none | narrow live, widen fixed | — | narrow quiet, widen notify |",
        ])
        self.assertIn("| `tools.mcp.server` | tools | server | notify |", (self.repo / "settings.md").read_text())

        # Known bad: a key added to the schema leaves the committed block stale.
        self.write("packages/gateway/src/admin/settings-schema.ts", schema.replace(
            '"background"]', '"background", "subagent"]'))
        self.assertIn("settings.md: `tron docs settings` is stale", self.docs("check", code=1))

    def test_check_against_a_base_needs_gateway_dependencies_only_when_a_loaded_block_can_change(self) -> None:
        """#1640: a Markdown-only change in a worktree without Gateway node_modules checks its generated docs."""
        schema = "export const KEYS = [];\nexport const RECORD_SUBJECTS = [];\n"
        self.module("packages/gateway/src/admin", "admin", {"settings-schema.ts": schema})
        self.module("packages/gateway/src/kernel/settings", "settings",
                    {"tool-contract.ts": "export const LAYERS = [];\n"})
        self.module("packages/gateway/src/main", "main", {"settings-schema.ts": """\
            import { KEYS, RECORD_SUBJECTS } from "../admin/settings-schema.js";
            export function createGatewaySettingsSchema() { return { KEYS, RECORD_SUBJECTS }; }
            """})
        self.write("settings.md", "<!-- tron docs settings -->\n<!-- /tron docs -->\n")
        self.write("other.md", "# Other\n")
        self.write("root.module.json", json.dumps({"layer": "L5", "owns": ["settings.md", "other.md", "root.module.json"]}))
        self.docs("update")
        # The schema now needs a package this worktree has not installed, as a fresh worktree's Gateway does.
        self.write("packages/gateway/src/admin/settings-schema.ts", 'import "@earendil-works/pi-ai";\n' + schema)
        self.git("add", "-A")
        self.git("-c", "user.name=F", "-c", "user.email=f@example.invalid", "commit", "-q", "-m", "base")
        missing = self.docs("check", code=1)
        self.assertIn("settings.md: loading packages/gateway/src/admin/settings-schema.ts needs the Gateway "
                      "dependencies, and packages/gateway/node_modules is missing (install with:", missing)
        self.assertIn("ERR_MODULE_NOT_FOUND", missing)
        self.write("other.md", "# Other, edited\n")
        self.assertEqual(self.docs("check", "--base", "main"), "docs: 1 generated block(s), current (1 unchanged "
                         "since main with unchanged sources, not regenerated)\n")
        # Known bad: an edited block, or a changed Gateway source, is regenerated against the base.
        self.write("settings.md", "<!-- tron docs settings -->\nhand-edited\n<!-- /tron docs -->\n")
        self.assertIn("node_modules is missing", self.docs("check", "--base", "main", code=1))
        self.write("settings.md", (self.repo / "settings.md").read_text().replace("hand-edited\n", ""))
        self.git("checkout", "-q", "--", "settings.md")
        self.write("packages/gateway/src/admin/other.ts", "export const x = 1;\n")
        self.assertIn("node_modules is missing", self.docs("check", "--base", "main", code=1))
        self.docs("check", "--base", "nope", code=1)

    def test_malformed_blocks_and_usage_fail(self) -> None:
        unclosed = "<!-- tron docs modules -->\nopen\n\n<!-- tron docs modules -->\nold\n<!-- /tron docs -->\n"
        self.write("open.md", unclosed)
        self.write("unknown.md", "<!-- tron docs nosuch -->\n<!-- /tron docs -->\n")
        self.write("root.module.json", json.dumps({"layer": "L5", "owns": ["open.md", "unknown.md", "root.module.json"]}))
        output = self.docs("check", code=1)
        self.assertIn("open.md: a `<!-- tron docs … -->` block has no `<!-- /tron docs -->` end", output)
        self.assertIn("unknown.md: unknown generator `tron docs nosuch`", output)
        self.docs("update", code=1)  # an unclosed opener never rewrites its file (it would swallow the next block)
        self.assertEqual((self.repo / "open.md").read_text(), unclosed)
        self.docs("nosuch", code=2)
        self.docs("signals", "extra", code=2)
        self.docs("check", "extra", code=2)
        missing = run(self.repo, self.env, "rpc")  # no gateway-service.ts: a named failure, not an empty list
        self.assertEqual(missing.returncode, 1)
        self.assertIn("cannot read packages/gateway/src/transport/gateway-service.ts", missing.stderr)


if __name__ == "__main__":
    unittest.main()
