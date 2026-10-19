import { readFile } from "node:fs/promises";

const [mode, resultPath] = process.argv.slice(2);
if (mode === "failure") process.exit(23);
if (mode !== "success" || !resultPath) process.exit(24);
const result = JSON.parse(await readFile(resultPath, "utf8"));
process.stdout.write(JSON.stringify(result));
