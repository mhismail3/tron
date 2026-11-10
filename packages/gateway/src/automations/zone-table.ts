/**
 * The UTC offsets of an IANA timezone around an instant, as data for proof block schedule/calendar
 * (packages/core/laws/schedule/Calendar.dfy): the offset before the first change and each change (instant, new
 * offset), in milliseconds. The block is integer arithmetic over this table; the table is its one trusted input
 * (block Assumption A1), read from Intl.
 *
 * Offsets are read at whole minutes, floored to the whole minute the local wall clock shows (a historical offset in
 * seconds, such as a zone's local mean time, shows its wall clock to the minute), so every offset and change
 * instant is a whole minute. Changes are found by sampling every SAMPLE_MS and bisecting a sampled difference to
 * the minute; two changes closer together than SAMPLE_MS that cancel out are not seen (no IANA zone has one in
 * the years automations use).
 */
export interface ZoneTable {
  readonly base: number;
  readonly changes: readonly { readonly at: number; readonly offset: number }[];
}

/** The table covers at least this long before and after the instant asked about (block Assumption A1). */
const ZONE_TABLE_REACH_MS = 19 * 24 * 60 * 60_000;
const DAY_MS = 24 * 60 * 60_000;
const MINUTE_MS = 60_000;
const SAMPLE_MS = 12 * 60 * 60_000;
const TABLES_KEPT = 64;

const tables = new Map<string, ZoneTable>();

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  let existing = formatters.get(timezone);
  if (!existing) {
    existing = new Intl.DateTimeFormat("en-US", { timeZone: timezone, numberingSystem: "latn", timeZoneName: "longOffset" });
    formatters.set(timezone, existing);
  }
  return existing;
}

/** The offset (local wall time minus UTC) at a whole-minute instant, to the whole minute the local wall clock shows. */
function offsetAt(timezone: string, minute: number): number {
  const text = formatter(timezone).format(minute);
  const offset = /GMT(?:([+-])(\d\d):(\d\d)(?::(\d\d))?)?$/u.exec(text);
  if (!offset) throw new Error(`Timezone offset is unreadable: ${text}`);
  const ms = offset[1] === undefined ? 0
    : (offset[1] === "-" ? -1 : 1) * (Number(offset[2]) * 3_600_000 + Number(offset[3]) * MINUTE_MS + Number(offset[4] ?? 0) * 1_000);
  return Math.floor(ms / MINUTE_MS) * MINUTE_MS;
}

/** The zone of `timezone` from ZONE_TABLE_REACH_MS before the UTC day of `at` to ZONE_TABLE_REACH_MS after it. */
export function zoneTable(timezone: string, at: number): ZoneTable {
  if (!Number.isFinite(at)) throw new Error("Zone table instant is invalid");
  const day = Math.floor(at / DAY_MS);
  const key = `${timezone}\0${day}`;
  let table = tables.get(key);
  if (!table) {
    table = build(timezone, day * DAY_MS - ZONE_TABLE_REACH_MS, (day + 1) * DAY_MS + ZONE_TABLE_REACH_MS);
    if (tables.size >= TABLES_KEPT) tables.delete(tables.keys().next().value!);
    tables.set(key, table);
  }
  return table;
}

function build(timezone: string, start: number, end: number): ZoneTable {
  const base = offsetAt(timezone, start);
  const changes: { at: number; offset: number }[] = [];
  let known = start;
  let offset = base;
  while (known < end) {
    const probe = Math.min(known + SAMPLE_MS, end);
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
