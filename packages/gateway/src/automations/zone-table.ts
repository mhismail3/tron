/**
 * The UTC offsets of an IANA timezone around an instant, as data for proof block schedule/calendar
 * (packages/core/laws/schedule/Calendar.dfy): the offset before the first change and each change (instant, new
 * offset), in milliseconds. The block is integer arithmetic over this table; the table is its one trusted input
 * (block Assumption A1), read from the same Intl data the calendar TypeScript in schedule.ts uses.
 *
 * Offsets are read at whole minutes (the local wall clock Intl shows, to the minute), so every offset and change
 * instant is a whole minute. Changes are found by sampling every SAMPLE_MS and bisecting a sampled difference to
 * the minute; two changes closer together than SAMPLE_MS that cancel out are not seen (no IANA zone has one in
 * the years automations use; the shadow comparison with schedule.ts would show it).
 */
export interface ZoneTable {
  base: number;
  changes: { at: number; offset: number }[];
}

/** The table covers this long before and after the instant asked about (block Assumption A1). */
const ZONE_TABLE_REACH_MS = 19 * 24 * 60 * 60_000;
const MINUTE_MS = 60_000;
const SAMPLE_MS = 12 * 60 * 60_000;

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  let existing = formatters.get(timezone);
  if (!existing) {
    existing = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone, calendar: "iso8601", numberingSystem: "latn", year: "numeric", month: "2-digit",
      day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    });
    formatters.set(timezone, existing);
  }
  return existing;
}

/** The offset (local wall time minus UTC) at a whole-minute instant. */
function offsetAt(timezone: string, minute: number): number {
  const parts: Record<string, number> = {};
  for (const part of formatter(timezone).formatToParts(minute)) parts[part.type] = Number(part.value);
  const local = new Date(0);
  local.setUTCFullYear(parts.year!, parts.month! - 1, parts.day!);
  local.setUTCHours(parts.hour!, parts.minute!, 0, 0);
  return local.getTime() - minute;
}

/** The zone of `timezone` from ZONE_TABLE_REACH_MS before `at` to ZONE_TABLE_REACH_MS after it. */
export function zoneTable(timezone: string, at: number): ZoneTable {
  if (!Number.isFinite(at)) throw new Error("Zone table instant is invalid");
  const start = Math.floor((at - ZONE_TABLE_REACH_MS) / MINUTE_MS) * MINUTE_MS;
  const end = at + ZONE_TABLE_REACH_MS;
  const base = offsetAt(timezone, start);
  const changes: ZoneTable["changes"] = [];
  let known = start;
  let offset = base;
  while (known < end) {
    const probe = Math.min(known + SAMPLE_MS, Math.ceil(end / MINUTE_MS) * MINUTE_MS);
    if (offsetAt(timezone, probe) === offset) {
      known = probe;
      continue;
    }
    // The first minute in (known, probe] whose offset differs from the one in effect at `known`.
    let low = known;
    let high = probe;
    while (high - low > MINUTE_MS) {
      const middle = low + Math.floor((high - low) / 2 / MINUTE_MS) * MINUTE_MS;
      if (offsetAt(timezone, middle) === offset) low = middle;
      else high = middle;
    }
    offset = offsetAt(timezone, high);
    changes.push({ at: high, offset });
    known = high;
  }
  return { base, changes };
}
