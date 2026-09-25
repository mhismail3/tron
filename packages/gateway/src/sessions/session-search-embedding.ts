import { execFile, spawn } from "node:child_process";
import { lstat, realpath } from "node:fs/promises";
import { promisify } from "node:util";

const MAX_TEXT_BYTES = 8 * 1_024;
const MAX_VECTOR_DIMENSION = 2_048;
const execFileAsync = promisify(execFile);

export async function admitSearchEmbeddingHelper(path: string, expectedTeam = "MYGKXH6TY4"): Promise<boolean> {
  try {
    const metadata = await lstat(path);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (metadata.mode & 0o111) === 0) return false;
    if (await realpath(path) !== path) return false;
    const result = await execFileAsync("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", path], { maxBuffer: 32 * 1024 });
    const details = await execFileAsync("/usr/bin/codesign", ["-dv", "--verbose=4", path], { maxBuffer: 64 * 1024 }).catch(() => undefined);
    const text = `${details?.stderr ?? ""}\n${details?.stdout ?? ""}`;
    return result !== undefined && /(?:^|\n)Identifier=TronSearchEmbeddingHelper(?:\n|$)/u.test(text)
      && new RegExp(`(?:^|\n)TeamIdentifier=${expectedTeam}(?:\n|$)`, "u").test(text)
      && /CodeDirectory .*flags=0x[0-9a-f]*1[0-9a-f]*\(runtime\)/iu.test(text)
      && !/Signature=adhoc/iu.test(text);
  } catch { return false; }
}

interface SearchEmbedding { vector: number[]; dimension: number; language: string; modelRevision: string; }

/** One-shot helper calls keep the signed process boundary simple and ensure a
 * crashed helper cannot strand a Gateway worker or retain transcript text. */
export class NaturalLanguageEmbeddingClient {
  constructor(private readonly helperPath: string, private readonly timeoutMs = 2_000) {}

  async qualify(signal?: AbortSignal): Promise<SearchEmbedding> {
    const first = await this.embed("A person is walking along a street.", "en", signal);
    const paraphrase = await this.embed("Someone walks down a road.", "en", signal);
    const negative = await this.embed("A database transaction has committed successfully.", "en", signal);
    const cosine = (left: readonly number[], right: readonly number[]) => {
      let dot = 0; let lm = 0; let rm = 0;
      for (let i = 0; i < left.length; i += 1) { dot += left[i]! * right[i]!; lm += left[i]! ** 2; rm += right[i]! ** 2; }
      return lm > 0 && rm > 0 ? dot / Math.sqrt(lm * rm) : -1;
    };
    if (first.dimension !== 512 || paraphrase.dimension !== first.dimension || negative.dimension !== first.dimension
      || paraphrase.language !== first.language || negative.language !== first.language
      || paraphrase.modelRevision !== first.modelRevision || negative.modelRevision !== first.modelRevision
      || cosine(first.vector, paraphrase.vector) < 0.45 || cosine(first.vector, negative.vector) > 0.9) throw new Error("Embedding helper failed semantic qualification");
    return first;
  }

  async embed(text: string, language = "en", signal?: AbortSignal): Promise<SearchEmbedding> {
    if (Buffer.byteLength(text, "utf8") > MAX_TEXT_BYTES) throw new Error("Embedding input exceeds its bound");
    if (signal?.aborted) throw new Error("Embedding cancelled");
    const child = spawn(this.helperPath, [], { stdio: ["pipe", "pipe", "ignore"] });
    const output: Buffer[] = [];
    const timer = setTimeout(() => child.kill("SIGKILL"), this.timeoutMs);
    const cancel = () => child.kill("SIGKILL");
    signal?.addEventListener("abort", cancel, { once: true });
    try {
      const result = await new Promise<string>((resolve, reject) => {
        child.stdout.on("data", (chunk: Buffer) => { output.push(chunk); if (Buffer.concat(output).byteLength > 128 * 1_024) child.kill("SIGKILL"); });
        child.once("error", reject);
        child.once("close", code => code === 0 ? resolve(Buffer.concat(output).toString("utf8")) : reject(new Error(`Embedding helper exited (${code ?? "signal"})`)));
        child.stdin.end(`${JSON.stringify({ id: "request", text, language })}\n`);
      });
      const value = JSON.parse(result.trim()) as { vector?: unknown; dimension?: unknown; language?: unknown; modelRevision?: unknown; reason?: unknown };
      const dimension = value.dimension;
      const validDimension = typeof dimension === "number" && Number.isSafeInteger(dimension) && dimension >= 1 && dimension <= MAX_VECTOR_DIMENSION;
      if (!Array.isArray(value.vector) || !validDimension || value.vector.length !== dimension || value.vector.some(item => typeof item !== "number" || !Number.isFinite(item))) {
        throw new Error(typeof value.reason === "string" ? value.reason : "Embedding helper returned an invalid vector");
      }
      const responseLanguage = typeof value.language === "string" ? value.language : "";
      const modelRevision = typeof value.modelRevision === "string" ? value.modelRevision : "";
      if (!responseLanguage || !modelRevision || responseLanguage !== language) throw new Error("Embedding helper returned unsupported language or model metadata");
      return { vector: value.vector, dimension, language: responseLanguage, modelRevision };
    } finally { clearTimeout(timer); signal?.removeEventListener("abort", cancel); if (!child.killed) child.kill("SIGKILL"); }
  }
}
