// Laws of block schedule/calendar: when an Automation's calendar trigger (a local wall-clock time on chosen
// weekdays in a timezone) next occurs, its latest occurrence at or before a time, its first occurrence at
// creation, and what a due occurrence dispatches or skips. Time is integer milliseconds since 1970-01-01 UTC.
// The timezone enters as data: a Zone is the UTC offset in effect before its first change plus each change
// (instant, new offset), built by the shell from Intl (packages/gateway/src/automations/zone-table.ts), so the
// block is integer arithmetic only (REPORT H9: the table is a trusted input).
// Shell: packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence, firstAutomationOccurrence,
// classifyDueOccurrence for calendar triggers; once and interval triggers are block schedule/occurrence).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module ScheduleCalendarLaws {
  const MINUTE := 60000
  const DAY := 86400000
  // The largest offset magnitude a zone may have: 18 hours (IANA offsets lie within -12 h and +14 h).
  const MAXOFF := 64800000

  datatype Change = Change(at: int, offset: int)
  datatype Zone = Zone(base: int, changes: seq<Change>)
  datatype Calendar = Calendar(minute: int, weekdays: seq<int>)
  datatype Policy = Latest | Skip
  datatype Opt = None | Some(v: int)
  datatype Result = Result(dispatchAt: Opt, next: Opt, skipped: Opt)

  // Assumption A1: the zone the shell passes agrees with the trigger's IANA timezone (Intl) at every instant
  // the call examines. The shell builds it from 19 days before to 19 days after the time passed (`after` for
  // Next, `now` for First and Classify, `b` for Prior), and every call examines less than 19 days either side.
  // Its offsets and change instants are whole minutes (so the earliest instant showing a local time is a whole
  // minute, as the TypeScript's minute scan finds), and its offsets lie within 18 hours. The laws hold for the
  // zone as given; A1 is what makes the zone the real timezone, and the shadow comparison with the Intl-based
  // TypeScript checks it on real traffic.
  // Assumption A2: the calendar's minute is the trigger's localTime as hours * 60 + minutes, and its weekdays
  // are the trigger's ISO weekdays (1 = Monday ... 7 = Sunday), which the automation contract validates as
  // non-empty, distinct and within 1-7. Compiled code does not check `requires`: the generated façade checks
  // Wf and WfCal before every call. Times are validated Gateway timestamps, so every value is a JS safe integer.

  // Wf: every offset is within 18 hours and changes are in strictly increasing order of instant.
  predicate Wf(z: Zone) {
    -MAXOFF <= z.base <= MAXOFF
    && (forall i | 0 <= i < |z.changes| :: -MAXOFF <= z.changes[i].offset <= MAXOFF)
    && (forall i | 0 <= i < |z.changes| - 1 :: z.changes[i].at < z.changes[i + 1].at)
  }

  // WfCal: the local time is a minute of the day (0 to 1439) and every weekday is between 1 and 7.
  predicate WfCal(c: Calendar) {
    0 <= c.minute < 1440 && forall i | 0 <= i < |c.weekdays| :: 1 <= c.weekdays[i] <= 7
  }

  // The UTC offset at instant t: the offset of the last change at or before t, or the base before the first.
  function Off(z: Zone, t: int): int { OffFrom(z.base, z.changes, t) }
  function OffFrom(base: int, cs: seq<Change>, t: int): int
    decreases |cs|
  { if |cs| == 0 || t < cs[0].at then base else OffFrom(cs[0].offset, cs[1..], t) }

  // The local wall-clock time shown at instant t, in milliseconds of local days since 1970-01-01.
  function Local(z: Zone, t: int): int { t + Off(z, t) }

  // The local date at instant t, counted in days since 1970-01-01 (negative before it).
  function LDate(z: Zone, t: int): int { Local(z, t) / DAY }

  // The ISO weekday of a local date: 1970-01-01 (date 0) was a Thursday (4); Monday = 1 ... Sunday = 7.
  function Weekday(d: int): int { (d + 3) % 7 + 1 }

  // InDay: instant t shows local date d at or after the calendar's local time on that date.
  ghost predicate InDay(z: Zone, d: int, minute: int, t: int) {
    d * DAY + minute * MINUTE <= Local(z, t) < (d + 1) * DAY
  }

  // Earliest: t is date d's occurrence of the local time: among the instants that show date d at or after
  // that local time, t shows the earliest local time, and t is the earliest instant showing it. So a time
  // that occurs twice (clocks set back) is its first instance, and a time skipped by clocks set forward
  // becomes the first local time after the jump on that date; a date with no such instant has none.
  ghost predicate Earliest(z: Zone, d: int, minute: int, t: int) {
    InDay(z, d, minute, t)
    && forall u: int | InDay(z, d, minute, u) ::
         Local(z, t) < Local(z, u) || (Local(z, t) == Local(z, u) && t <= u)
  }

  // Occ: t is an occurrence of the calendar: its local date is one of the weekdays, and t is that date's
  // occurrence of the local time.
  ghost predicate Occ(z: Zone, c: Calendar, t: int) {
    Weekday(LDate(z, t)) in c.weekdays && Earliest(z, LDate(z, t), c.minute, t)
  }

  // Horizon: Next looks no further than 18 hours (the largest offset) before the end of the sixteenth local
  // date after the local date of `after`; this is always more than 14 days after `after`.
  function Horizon(z: Zone, after: int): int { (LDate(z, after) + 17) * DAY - MAXOFF }

  // Floor: Prior looks no further back than 18 hours after the start of the sixteenth local date before the
  // local date of `b`; this is always more than 14 days before `b`.
  function Floor(z: Zone, b: int): int { (LDate(z, b) - 16) * DAY + MAXOFF }

  // The next occurrence strictly after `after`, within the horizon.
  function Next(z: Zone, c: Calendar, after: int): Opt
    requires Wf(z) && WfCal(c)

  // The prior occurrence: the latest one at or before `b`, within the floor.
  function Prior(z: Zone, c: Calendar, b: int): Opt
    requires Wf(z) && WfCal(c)

  // The first occurrence for a trigger created at `now`.
  function First(z: Zone, c: Calendar, now: int): Opt
    requires Wf(z) && WfCal(c)

  // What a stored next occurrence `nxt` does at time `now` under policy `p`.
  function Classify(z: Zone, c: Calendar, nxt: int, now: int, p: Policy): Result
    requires Wf(z) && WfCal(c)

  // N1 next-sound: a reported next occurrence is a real occurrence of the calendar, strictly after the given
  // time and before the horizon.
  lemma N1NextSound(z: Zone, c: Calendar, after: int)
    requires Wf(z) && WfCal(c) && Next(z, c, after).Some?
    ensures var x := Next(z, c, after).v; after < x < Horizon(z, after) && Occ(z, c, x)

  // N2 next-least: no occurrence is skipped: every occurrence strictly after the given time is at or after
  // the reported next occurrence (also one beyond the horizon).
  lemma N2NextLeast(z: Zone, c: Calendar, after: int, y: int)
    requires Wf(z) && WfCal(c) && Next(z, c, after).Some? && Occ(z, c, y) && y > after
    ensures Next(z, c, after).v <= y

  // N3 next-complete: whenever an occurrence lies strictly after the given time and before the horizon (so
  // at least every occurrence within the next 14 days), a next occurrence is reported.
  lemma N3NextComplete(z: Zone, c: Calendar, after: int, y: int)
    requires Wf(z) && WfCal(c) && Occ(z, c, y) && after < y < Horizon(z, after)
    ensures Next(z, c, after).Some?

  // N4 next-progress: in a zone whose offset never changes, a calendar with at least one weekday always has a
  // next occurrence, at most eight days after the given time.
  lemma N4NextProgress(z: Zone, c: Calendar, after: int)
    requires Wf(z) && WfCal(c) && |z.changes| == 0 && |c.weekdays| > 0
    ensures Next(z, c, after).Some? && Next(z, c, after).v <= after + 8 * DAY

  // P1 prior-sound: a reported prior occurrence is a real occurrence at or before the given time and at or
  // after the floor.
  lemma P1PriorSound(z: Zone, c: Calendar, b: int)
    requires Wf(z) && WfCal(c) && Prior(z, c, b).Some?
    ensures var x := Prior(z, c, b).v; Floor(z, b) <= x <= b && Occ(z, c, x)

  // P2 prior-greatest: every occurrence at or before the given time is at or before the reported prior one.
  lemma P2PriorGreatest(z: Zone, c: Calendar, b: int, y: int)
    requires Wf(z) && WfCal(c) && Prior(z, c, b).Some? && Occ(z, c, y) && y <= b
    ensures y <= Prior(z, c, b).v

  // P3 prior-complete: whenever an occurrence lies at or before the given time and at or after the floor
  // (so at least every occurrence within the last 14 days), a prior occurrence is reported.
  lemma P3PriorComplete(z: Zone, c: Calendar, b: int, y: int)
    requires Wf(z) && WfCal(c) && Occ(z, c, y) && Floor(z, b) <= y <= b
    ensures Prior(z, c, b).Some?

  // F1 first: the first occurrence for a trigger created at `now` is the next one after one millisecond
  // before now, so an occurrence exactly at now counts.
  lemma F1First(z: Zone, c: Calendar, now: int)
    requires Wf(z) && WfCal(c)
    ensures First(z, c, now) == Next(z, c, now - 1)

  // C1 classify-not-due: if the stored next occurrence is still in the future, nothing is dispatched or
  // skipped and the stored next occurrence is kept unchanged.
  lemma C1ClassifyNotDue(z: Zone, c: Calendar, nxt: int, now: int, p: Policy)
    requires Wf(z) && WfCal(c) && nxt > now
    ensures Classify(z, c, nxt, now, p) == Result(None, Some(nxt), None)

  // C2 classify-due: if the stored next occurrence is due (at or before now), the latest occurrence at or
  // before now is dispatched under the "latest" policy or skipped under "skip" (nothing when there is none),
  // and the new stored next occurrence is the next one after now. The stored value is only compared with now,
  // so a stale one (from an edited trigger) never makes a time that is not an occurrence fire.
  lemma C2ClassifyDue(z: Zone, c: Calendar, nxt: int, now: int, p: Policy)
    requires Wf(z) && WfCal(c) && nxt <= now
    ensures Classify(z, c, nxt, now, p)
      == if p == Latest then Result(Prior(z, c, now), Next(z, c, now), None)
         else Result(None, Next(z, c, now), Prior(z, c, now))
}
