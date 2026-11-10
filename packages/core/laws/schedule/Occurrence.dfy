// Laws of block schedule/occurrence: when an Automation's once or interval trigger next occurs, the first
// occurrence at creation, and what a due occurrence dispatches or skips. Time is integer milliseconds.
// Shell: packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence, firstAutomationOccurrence,
// classifyDueOccurrence for once and interval triggers; calendar triggers are not in this block).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module ScheduleOccurrenceLaws {
  // Ms: a time or a period in milliseconds, as a JavaScript safe integer. The compiled block computes with
  // JavaScript numbers, and the proof shows that no value it computes leaves this range, so its arithmetic is
  // exact.
  newtype Ms = x: int | -0x20_0000_0000_0000 < x < 0x20_0000_0000_0000
  // The furthest time from 1970 and the longest period the block accepts: 2^50 ms, about 35,000 years.
  const LIMIT: Ms := 0x4_0000_0000_0000

  datatype Trigger = Once(at: Ms) | Interval(anchor: Ms, every: Ms)
  datatype Policy = Latest | Skip
  datatype Opt = None | Some(v: Ms)
  datatype Result = Result(dispatchAt: Opt, next: Opt, skipped: Opt)

  // Assumption A1: the shell calls these functions only with well-formed triggers and times in range.
  // Interval periods come from the automation contract (everySeconds an integer in [60, 31536000]) and times
  // are milliseconds of validated Gateway timestamps (years 0000-9999) or of the clock, far inside LIMIT.
  // Compiled code does not check `requires`: the generated façade checks Wf and InRange before every call and
  // refuses a number that is not a safe integer.
  // Assumption A2: the stored next occurrence given to Classify is an occurrence of the trigger as it is
  // now. The shell sets it only from First, Next or Classify of the current trigger; an edit while paused
  // keeps the old value, but the scheduler classifies only enabled Automations and enabling recomputes it
  // with First (or keeps it when a retained run carries the same, unchanged trigger). The store's record
  // validator admits any timestamp when reading, so this also assumes nothing else writes the store.

  // InRange: a time within LIMIT of 1970.
  predicate InRange(x: Ms) { -LIMIT <= x <= LIMIT }

  // Wf: a trigger is well-formed when its time is in range and, for an interval, its period is positive and
  // at most LIMIT.
  predicate Wf(t: Trigger) {
    match t
    case Once(at) => InRange(at)
    case Interval(a, e) => InRange(a) && 0 < e <= LIMIT
  }

  // x is an occurrence of t.
  ghost predicate Occ(t: Trigger, x: int) {
    match t
    case Once(at) => x == at as int
    case Interval(a, e) => var anchor, every := a as int, e as int; exists k: nat :: x == anchor + k * every
  }

  // Witness: L is a real occurrence of the trigger between nxt and now (inclusive), and it is the latest
  // such occurrence: no occurrence falls after L and at or before now.
  ghost predicate Witness(t: Trigger, nxt: int, now: int, L: int) {
    Occ(t, L) && nxt <= L <= now && forall x: int | Occ(t, x) && L < x <= now :: false
  }

  // The next occurrence strictly after `after`.
  function Next(t: Trigger, after: Ms): Opt
    requires Wf(t) && InRange(after)

  // The first occurrence for a trigger created at `now`.
  function First(t: Trigger, now: Ms): Opt
    requires Wf(t) && InRange(now)

  // What a stored next occurrence `nxt` does at time `now` under policy `p`.
  function Classify(t: Trigger, nxt: Ms, now: Ms, p: Policy): Result
    requires Wf(t) && InRange(nxt) && InRange(now)

  // L1 next-sound: whenever the next occurrence after a time is reported, it is strictly later than that
  // time and it is a real occurrence of the trigger (the anchor plus a whole number of periods, or the
  // once-time itself).
  lemma L1NextSound(t: Trigger, after: Ms)
    requires Wf(t) && InRange(after) && Next(t, after).Some?
    ensures Next(t, after).v > after && Occ(t, Next(t, after).v as int)

  // L2 next-minimal: no occurrence is ever skipped: for any real occurrence later than the given time, a
  // next occurrence is reported and it is no later than that one.
  lemma L2NextMinimal(t: Trigger, after: Ms, x: int)
    requires Wf(t) && InRange(after) && Occ(t, x) && x > after as int
    ensures Next(t, after).Some? && Next(t, after).v as int <= x

  // L3 next-none: "no next occurrence" is reported exactly when the trigger is a one-shot whose time is
  // at or before the given time; an interval trigger always has a next occurrence.
  lemma L3NextNone(t: Trigger, after: Ms)
    requires Wf(t) && InRange(after)
    ensures Next(t, after).None? <==> (t.Once? && t.at <= after)

  // L4 first-interval: for an interval trigger, the first occurrence at creation time `now` is a real
  // occurrence at or after now, and no real occurrence at or after now comes before it.
  lemma L4FirstInterval(t: Trigger, now: Ms)
    requires Wf(t) && InRange(now) && t.Interval?
    ensures var f := First(t, now);
      f.Some? && f.v >= now && Occ(t, f.v as int) && forall x: int | Occ(t, x) && x >= now as int :: f.v as int <= x

  // L5 classify-not-due: if the stored next occurrence is still in the future, nothing is dispatched or
  // skipped and the stored next occurrence is kept unchanged.
  lemma L5ClassifyNotDue(t: Trigger, nxt: Ms, now: Ms, p: Policy)
    requires Wf(t) && InRange(nxt) && InRange(now) && nxt > now
    ensures Classify(t, nxt, now, p) == Result(None, Some(nxt), None)

  // L6 classify-due: if the stored next occurrence is real and due (at or before now), exactly one
  // occurrence is acted on: dispatched under the "latest" policy, skipped under "skip". It is the latest
  // occurrence that is due (a Witness), and the new stored next occurrence is the first one after now for
  // an interval trigger, or none for a one-shot; a new stored next occurrence is strictly after now.
  lemma L6ClassifyDue(t: Trigger, nxt: Ms, now: Ms, p: Policy)
    requires Wf(t) && InRange(nxt) && InRange(now) && Occ(t, nxt as int) && nxt <= now
    ensures var d := Classify(t, nxt, now, p);
      (d.dispatchAt.Some? != d.skipped.Some?)
      && (d.dispatchAt.Some? <==> p == Latest)
      && (d.dispatchAt.Some? ==> Witness(t, nxt as int, now as int, d.dispatchAt.v as int))
      && (d.skipped.Some? ==> Witness(t, nxt as int, now as int, d.skipped.v as int))
      && (if t.Interval? then d.next == Next(t, now) else d.next == None)
      && (d.next.Some? ==> d.next.v > now)

  // L7 first-once: for a one-shot trigger the first occurrence is always its own time, even when that
  // time is already in the past (the scheduler then dispatches or skips it).
  lemma L7FirstOnce(at: Ms, now: Ms)
    requires InRange(at) && InRange(now)
    ensures First(Once(at), now) == Some(at)

  // L8 first-after-occurrence: an interval trigger created one millisecond after one of its occurrences
  // does not count that past occurrence: its first occurrence is the next one, a whole period later.
  lemma L8FirstAfterOccurrence(a: Ms, e: Ms, k: nat)
    requires InRange(a) && 0 < e <= LIMIT && a as int + k * (e as int) < LIMIT as int
    ensures First(Interval(a, e), (a as int + k * (e as int) + 1) as Ms) == Some((a as int + (k + 1) * (e as int)) as Ms)
}
