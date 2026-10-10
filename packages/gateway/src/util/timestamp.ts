export function isGatewayTimestamp(value: string): boolean {
  if (Buffer.byteLength(value) > 64) return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = match[9] === undefined ? 0 : Number(match[9]);
  const offsetMinute = match[10] === undefined ? 0 : Number(match[10]);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59
    || offsetHour > 23 || offsetMinute > 59) return false;
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day >= 1 && day <= daysInMonth && Number.isFinite(Date.parse(value));
}

/**
 * One instant as the local date and time of the machine reading it, always with
 * the offset that makes it unambiguous: `2026-01-02 15:04:05 -07:00`. Tron Home's
 * `date` tool shows a message's time this way. `undefined` for a value that is
 * not an instant, so a caller reports that it cannot answer instead of inventing
 * a time.
 */
export function localTimestampText(instant: string): string | undefined {
  const at = new Date(instant);
  if (!Number.isFinite(at.getTime())) return undefined;
  const pad = (part: number): string => String(part).padStart(2, "0");
  // getTimezoneOffset() is minutes *behind* UTC, at the instant itself (so a
  // historic instant keeps the offset that was in force then).
  const offset = -at.getTimezoneOffset();
  const sign = offset < 0 ? "-" : "+";
  const minutes = Math.abs(offset);
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
    + ` ${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`
    + ` ${sign}${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}
