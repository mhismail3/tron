import { execFile } from "node:child_process";
import { freemem, totalmem } from "node:os";

export interface HostMemory {
  freeBytes: number;
  totalBytes: number;
  swapUsedBytes?: number;
  swapTotalBytes?: number;
  pressure?: "normal" | "warn" | "critical";
  memoryAvailablePercent?: number;
}

type HostKernelFacts = Omit<HostMemory, "freeBytes" | "totalBytes">;

const SYSCTL_TIMEOUT_MS = 1_000;

const HOST_SYSCTL_NAMES = ["vm.swapusage", "kern.memorystatus_vm_pressure_level", "kern.memorystatus_level"] as const;

const SIZE_SCALE = { K: 1_024, M: 1_024 ** 2, G: 1_024 ** 3, T: 1_024 ** 4 } as const;

function parseSize(text: string, label: string): number | undefined {
  const match = new RegExp(`${label} = ([\\d.]+)([KMGT])`, "u").exec(text);
  if (!match) return undefined;
  const value = Number(match[1]);
  return Number.isFinite(value) ? Math.round(value * SIZE_SCALE[match[2] as keyof typeof SIZE_SCALE]) : undefined;
}

function parseMemoryPressure(text: string): HostMemory["pressure"] {
  switch (text.trim()) {
    case "1": return "normal";
    case "2": return "warn";
    case "4": return "critical";
    default: return undefined;
  }
}

function parseMemoryAvailablePercent(text: string): number | undefined {
  if (!/^\d+$/u.test(text.trim())) return undefined;
  const value = Number(text.trim());
  return value <= 100 ? value : undefined;
}

function parseHostSysctl(text: string): HostKernelFacts {
  const lines = text.split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
  const swapIndex = lines.findIndex((line) => line.includes("total ="));
  const swap = swapIndex < 0 ? "" : lines[swapIndex]!;
  const values = lines.filter((_, index) => index !== swapIndex);
  const swapTotalBytes = parseSize(swap, "total");
  const swapUsedBytes = parseSize(swap, "used");
  const pressure = parseMemoryPressure(values[0] ?? "");
  const memoryAvailablePercent = parseMemoryAvailablePercent(values[1] ?? "");
  return {
    ...(swapTotalBytes === undefined ? {} : { swapTotalBytes }),
    ...(swapUsedBytes === undefined ? {} : { swapUsedBytes }),
    ...(pressure === undefined ? {} : { pressure }),
    ...(memoryAvailablePercent === undefined ? {} : { memoryAvailablePercent }),
  };
}

function sysctl(names: readonly string[]): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("/usr/sbin/sysctl", ["-n", ...names], { timeout: SYSCTL_TIMEOUT_MS, maxBuffer: 4_096 }, (error, stdout) => {
      resolve(error && stdout.length === 0 ? undefined : stdout);
    });
  });
}

async function probeHostKernel(
  run: (names: readonly string[]) => Promise<string | undefined> = sysctl,
): Promise<HostKernelFacts> {
  const text = await run(HOST_SYSCTL_NAMES);
  return text === undefined ? {} : parseHostSysctl(text);
}

export async function sampleHostMemory(): Promise<HostMemory> {
  const base = { freeBytes: freemem(), totalBytes: totalmem() };
  if (process.platform !== "darwin") return base;
  return { ...base, ...await probeHostKernel() };
}
