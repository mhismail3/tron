import { mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const RETAINED_DAYS = 30;
const GAP_BUCKETS = [["lt5m", 5 * 60_000], ["lt1h", 60 * 60_000], ["gte1h", Infinity]] as const;

interface KindCounts {
  requests: number;
  skillIndexRequests: number;
  gaps: Record<(typeof GAP_BUCKETS)[number][0], number>;
  calls: Record<string, number>;
  skillOpens: Record<string, number>;
}

interface DayCounts {
  day: string;
  since: string;
  kinds: Record<string, KindCounts>;
}

export class ObservationCounts {
  private current: DayCounts | undefined;
  private readonly lastRequest = new Map<string, number>();

  constructor(private readonly directory: string) {}

  request(record: { sessionId: string; kind: string; skillIndex: boolean }): void {
    const at = new Date();
    const previous = this.lastRequest.get(record.sessionId);
    this.lastRequest.set(record.sessionId, at.getTime());
    this.update(at, record.kind, counts => {
      counts.requests += 1;
      if (record.skillIndex) counts.skillIndexRequests += 1;
      if (previous !== undefined) counts.gaps[GAP_BUCKETS.find(([, limit]) => at.getTime() - previous < limit)![0]] += 1;
    });
  }

  call(aggregate: { name: string; kind: string; status: string; skill?: string }): void {
    this.update(new Date(), aggregate.kind, counts => {
      counts.calls[aggregate.name] = (counts.calls[aggregate.name] ?? 0) + 1;
      if (aggregate.skill && aggregate.status === "ok") counts.skillOpens[aggregate.skill] = (counts.skillOpens[aggregate.skill] ?? 0) + 1;
    });
  }

  private update(at: Date, kind: string, change: (counts: KindCounts) => void): void {
    try {
      const day = at.toISOString().slice(0, 10);
      if (this.current?.day !== day) this.current = this.open(day, at);
      const counts = this.current.kinds[kind] ??= { requests: 0, skillIndexRequests: 0, gaps: { lt5m: 0, lt1h: 0, gte1h: 0 }, calls: {}, skillOpens: {} };
      change(counts);
      const path = join(this.directory, `${day}.json`);
      writeFileSync(`${path}.tmp`, `${JSON.stringify(this.current)}\n`, { mode: 0o600 });
      renameSync(`${path}.tmp`, path);
    } catch {
      this.current = undefined;
    }
  }

  private open(day: string, at: Date): DayCounts {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const days = readdirSync(this.directory).filter(name => /^\d{4}-\d{2}-\d{2}\.json$/u.test(name) && name !== `${day}.json`).sort();
    for (const name of days.slice(0, Math.max(0, days.length - RETAINED_DAYS + 1))) unlinkSync(join(this.directory, name));
    try {
      return JSON.parse(readFileSync(join(this.directory, `${day}.json`), "utf8")) as DayCounts;
    } catch {
      return { day, since: at.toISOString(), kinds: {} };
    }
  }
}
