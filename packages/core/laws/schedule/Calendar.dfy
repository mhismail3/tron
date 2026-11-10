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
  // Ms: a time, offset or duration in milliseconds, as a JavaScript safe integer. The compiled block computes
  // with JavaScript numbers, and the proof shows that no value it computes leaves this range, so its arithmetic
  // is exact. The definitions the laws use below compute over unbounded integers.
  newtype Ms = x: int | -0x20_0000_0000_0000 < x < 0x20_0000_0000_0000
  // The furthest time from 1970 the block accepts: 2^50 ms, about 35,000 years.
  const LIMIT: Ms := 0x4_0000_0000_0000
  const MINUTE: Ms := 60000
  const DAY: Ms := 86400000
  // The largest offset magnitude a zone may have: 18 hours (IANA offsets lie within -12 h and +14 h).
  const MAXOFF: Ms := 64800000

  // A list, crossing to the shell as an array.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  datatype Change = Change(at: Ms, offset: Ms)
  datatype Zone = Zone(base: Ms, changes: List<Change>)
  datatype Calendar = Calendar(minute: Ms, weekdays: List<Ms>)
  datatype Policy = Latest | Skip
  datatype Opt = None | Some(v: Ms)
  datatype Result = Result(dispatchAt: Opt, next: Opt, skipped: Opt)

  // Assumption A1: the zone the shell passes agrees with the trigger's IANA timezone (Intl) at every instant
  // the call examines. The shell builds it from at least 19 days before to at least 19 days after the time
  // passed (`after` for Next, `now` for First and Classify, `b` for Prior), and every call examines less than
  // 19 days either side. Its offsets and change instants are whole minutes (so the earliest instant showing a
  // local time is a whole minute, as the TypeScript's minute scan found), and its offsets lie within 18 hours.
  // The laws hold for the zone as given; A1 is what makes the zone the real timezone, and the old-against-new
  // comparison with the Intl-based TypeScript at the cut-over checked it.
  // Assumption A2: the calendar's minute is the trigger's localTime as hours * 60 + minutes, and its weekdays
  // are the trigger's ISO weekdays (1 = Monday ... 7 = Sunday), which the automation contract validates as
  // non-empty, distinct and within 1-7. Compiled code does not check `requires`: the generated façade checks
  // Wf, WfCal and InRange before every call and refuses a number that is not a safe integer. Times are
  // milliseconds of validated Gateway timestamps (years 0000-9999) or of the clock, far inside LIMIT.

  // InRange: a time within LIMIT of 1970.
  predicate InRange(x: Ms) { -LIMIT <= x <= LIMIT }

  // Wf: every offset is within 18 hours, every change instant is in range, and changes are in strictly
  // increasing order of instant.
  predicate Wf(z: Zone) { -MAXOFF <= z.base <= MAXOFF && WfChanges(z.changes) }
  predicate WfChanges(cs: List<Change>) {
    if cs.Nil? then true
    else if !(InRange(cs.head.at) && -MAXOFF <= cs.head.offset <= MAXOFF) then false
    else if cs.tail.Cons? && cs.tail.head.at <= cs.head.at then false
    else WfChanges(cs.tail)
  }

  // WfCal: the local time is a minute of the day (0 to 1439) and every weekday is between 1 and 7.
  predicate WfCal(c: Calendar) { 0 <= c.minute < 1440 && WfWeekdays(c.weekdays) }
  predicate WfWeekdays(ws: List<Ms>) {
    if ws.Nil? then true else if !(1 <= ws.head <= 7) then false else WfWeekdays(ws.tail)
  }

  // w is one of the weekdays.
  ghost predicate On(ws: List<Ms>, w: int) { ws.Cons? && (ws.head as int == w || On(ws.tail, w)) }

  // The UTC offset at instant t: the offset of the last change at or before t, or the base before the first.
  ghost function Off(z: Zone, t: int): int { OffFrom(z.base as int, z.changes, t) }
  ghost function OffFrom(base: int, cs: List<Change>, t: int): int
    decreases cs
  { if cs.Nil? || t < cs.head.at as int then base else OffFrom(cs.head.offset as int, cs.tail, t) }

  // The local wall-clock time shown at instant t, in milliseconds of local days since 1970-01-01.
  ghost function Local(z: Zone, t: int): int { t + Off(z, t) }

  // The local date at instant t, counted in days since 1970-01-01 (negative before it).
  ghost function LDate(z: Zone, t: int): int { Local(z, t) / DAY as int }

  // The ISO weekday of a local date: 1970-01-01 (date 0) was a Thursday (4); Monday = 1 ... Sunday = 7.
  ghost function Weekday(d: int): int { (d + 3) % 7 + 1 }

  // InDay: instant t shows local date d at or after the calendar's local time on that date.
  ghost predicate InDay(z: Zone, d: int, minute: int, t: int) {
    d * DAY as int + minute * MINUTE as int <= Local(z, t) < (d + 1) * DAY as int
  }

  // Earliest: t is date d's occurrence of the local time: among the instants that show date d at or after
  // that local time, t shows the earliest local time, and t is the earliest instant showing it. So a time
  // that occurs twice (clocks set back) is its first instance, and a time skipped by clocks set forward
  // becomes the first local time after the jump on that date; a date with no such instant (a civil date the
  // zone skips entirely, or one whose instants all show an earlier local time) has none, and is skipped.
  ghost predicate Earliest(z: Zone, d: int, minute: int, t: int) {
    InDay(z, d, minute, t)
    && forall u: int | InDay(z, d, minute, u) ::
         Local(z, t) < Local(z, u) || (Local(z, t) == Local(z, u) && t <= u)
  }

  // Occ: t is an occurrence of the calendar: its local date is one of the weekdays, and t is that date's
  // occurrence of the local time.
  ghost predicate Occ(z: Zone, c: Calendar, t: int) {
    On(c.weekdays, Weekday(LDate(z, t))) && Earliest(z, LDate(z, t), c.minute as int, t)
  }

  // Horizon: Next looks no further than 18 hours (the largest offset) before the end of the sixteenth local
  // date after the local date of `after`; this is always more than 14 days after `after`.
  ghost function Horizon(z: Zone, after: int): int { (LDate(z, after) + 17) * DAY as int - MAXOFF as int }

  // Floor: Prior looks no further back than 18 hours after the start of the sixteenth local date before the
  // local date of `b`; this is always more than 14 days before `b`.
  ghost function Floor(z: Zone, b: int): int { (LDate(z, b) - 16) * DAY as int + MAXOFF as int }

  // The next occurrence strictly after `after`, within the horizon.
  function Next(z: Zone, c: Calendar, after: Ms): Opt
    requires Wf(z) && WfCal(c) && InRange(after)

  // The prior occurrence: the latest one at or before `b`, within the floor.
  function Prior(z: Zone, c: Calendar, b: Ms): Opt
    requires Wf(z) && WfCal(c) && InRange(b)

  // The first occurrence for a trigger created at `now`.
  function First(z: Zone, c: Calendar, now: Ms): Opt
    requires Wf(z) && WfCal(c) && InRange(now)

  // What a stored next occurrence `nxt` does at time `now` under policy `p`.
  function Classify(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy): Result
    requires Wf(z) && WfCal(c) && InRange(nxt) && InRange(now)

  // N1 next-sound: a reported next occurrence is a real occurrence of the calendar, strictly after the given
  // time and before the horizon.
  lemma N1NextSound(z: Zone, c: Calendar, after: Ms)
    requires Wf(z) && WfCal(c) && InRange(after) && Next(z, c, after).Some?
    ensures var x := Next(z, c, after).v as int; after as int < x < Horizon(z, after as int) && Occ(z, c, x)

  // N2 next-least: no occurrence is skipped: every occurrence strictly after the given time is at or after
  // the reported next occurrence (also one beyond the horizon).
  lemma N2NextLeast(z: Zone, c: Calendar, after: Ms, y: int)
    requires Wf(z) && WfCal(c) && InRange(after) && Next(z, c, after).Some? && Occ(z, c, y) && y > after as int
    ensures Next(z, c, after).v as int <= y

  // N3 next-complete: whenever an occurrence lies strictly after the given time and before the horizon (so
  // at least every occurrence within the next 14 days), a next occurrence is reported.
  lemma N3NextComplete(z: Zone, c: Calendar, after: Ms, y: int)
    requires Wf(z) && WfCal(c) && InRange(after) && Occ(z, c, y) && after as int < y < Horizon(z, after as int)
    ensures Next(z, c, after).Some?

  // N4 next-progress: in a zone whose offset never changes, a calendar with at least one weekday always has a
  // next occurrence, at most eight days after the given time.
  lemma N4NextProgress(z: Zone, c: Calendar, after: Ms)
    requires Wf(z) && WfCal(c) && InRange(after) && z.changes.Nil? && c.weekdays.Cons?
    ensures Next(z, c, after).Some? && Next(z, c, after).v as int <= after as int + 8 * DAY as int

  // P1 prior-sound: a reported prior occurrence is a real occurrence at or before the given time and at or
  // after the floor.
  lemma P1PriorSound(z: Zone, c: Calendar, b: Ms)
    requires Wf(z) && WfCal(c) && InRange(b) && Prior(z, c, b).Some?
    ensures var x := Prior(z, c, b).v as int; Floor(z, b as int) <= x <= b as int && Occ(z, c, x)

  // P2 prior-greatest: every occurrence at or before the given time is at or before the reported prior one.
  lemma P2PriorGreatest(z: Zone, c: Calendar, b: Ms, y: int)
    requires Wf(z) && WfCal(c) && InRange(b) && Prior(z, c, b).Some? && Occ(z, c, y) && y <= b as int
    ensures y <= Prior(z, c, b).v as int

  // P3 prior-complete: whenever an occurrence lies at or before the given time and at or after the floor
  // (so at least every occurrence within the last 14 days), a prior occurrence is reported.
  lemma P3PriorComplete(z: Zone, c: Calendar, b: Ms, y: int)
    requires Wf(z) && WfCal(c) && InRange(b) && Occ(z, c, y) && Floor(z, b as int) <= y <= b as int
    ensures Prior(z, c, b).Some?

  // F1 first: the first occurrence for a trigger created at `now` is the next one after one millisecond
  // before now, so an occurrence exactly at now counts. (At now = -LIMIT, about 33,000 BC, that time is out
  // of range and the law says nothing.)
  lemma F1First(z: Zone, c: Calendar, now: Ms)
    requires Wf(z) && WfCal(c) && InRange(now) && InRange(now - 1)
    ensures First(z, c, now) == Next(z, c, now - 1)

  // C1 classify-not-due: if the stored next occurrence is still in the future, nothing is dispatched or
  // skipped and the stored next occurrence is kept unchanged.
  lemma C1ClassifyNotDue(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy)
    requires Wf(z) && WfCal(c) && InRange(nxt) && InRange(now) && nxt > now
    ensures Classify(z, c, nxt, now, p) == Result(None, Some(nxt), None)

  // C2 classify-due: if the stored next occurrence is due (at or before now), the latest occurrence at or
  // before now is dispatched under the "latest" policy or skipped under "skip" (nothing when there is none),
  // and the new stored next occurrence is the next one after now. The stored value is only compared with now,
  // so a stale one (from an edited trigger) never makes a time that is not an occurrence fire.
  lemma C2ClassifyDue(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy)
    requires Wf(z) && WfCal(c) && InRange(nxt) && InRange(now) && nxt <= now
    ensures Classify(z, c, nxt, now, p)
      == if p == Latest then Result(Prior(z, c, now), Next(z, c, now), None)
         else Result(None, Next(z, c, now), Prior(z, c, now))
}
