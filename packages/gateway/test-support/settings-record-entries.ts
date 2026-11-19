import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { ChangeEntry } from "../src/kernel/settings/settings-record.js";

export async function settingsRecordEntries(tronHome: string, key?: string): Promise<ChangeEntry[]> {
  const directory = join(tronHome, "state/settings/changes");
  const names = (await readdir(directory).catch(() => [] as string[])).filter(name => name.endsWith(".jsonl")).sort();
  const rows: ChangeEntry[] = [];
  for (const name of names) {
    const text = await readFile(join(directory, name), "utf8");
    rows.push(...text.split("\n").filter(Boolean).map(line => JSON.parse(line) as ChangeEntry));
  }
  return rows.filter(entry => key === undefined || entry.key === key).reverse();
}
