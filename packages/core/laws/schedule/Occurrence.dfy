// Laws of block schedule/occurrence: when an Automation's once or interval trigger next occurs, the first
// occurrence at creation, and what a due occurrence dispatches or skips. Time is integer milliseconds.
// Shell: packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence, firstAutomationOccurrence,
// classifyDueOccurrence for once and interval triggers; calendar triggers are not in this block).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module ScheduleOccurrenceLaws {
  datatype Trigger = Once(at: int) | Interval(anchor: int, every: int)
  datatype Policy = Latest | Skip
  datatype Opt = None | Some(v: int)
  datatype Result = Result(dispatchAt: Opt, next: Opt, skipped: Opt)

  // Assumption A1: the shell calls these functions only with well-formed triggers (Wf: a non-positive
  // period is rejected at the boundary; Tron's TS does not check it today) and with times in
  // 0 <= t < 2^47 ms, so the JS marshalling (BigNumber <-> number) is exact.
  // Wf: a trigger is well-formed when it is one-shot or its period is positive.
  predicate Wf(t: Trigger) { t.Once? || t.every > 0 }

  // x is an occurrence of t.
  ghost predicate Occ(t: Trigger, x: int) {
    match t
    case Once(at) => x == at
    case Interval(a, e) => exists k: nat :: x == a + k * e
  }

  // Witness: L is a real occurrence of the trigger between nxt and now (inclusive), and it is the latest
  // such occurrence: no occurrence falls after L and at or before now.
  ghost predicate Witness(t: Trigger, nxt: int, now: int, L: int) {
    Occ(t, L) && nxt <= L <= now && forall x: int | Occ(t, x) && L < x <= now :: false
  }

  // The next occurrence strictly after `after`.
  function Next(t: Trigger, after: int): Opt
    requires Wf(t)

  // The first occurrence for a trigger created at `now`.
  function First(t: Trigger, now: int): Opt
    requires Wf(t)

  // What a stored next occurrence `nxt` does at time `now` under policy `p`.
  function Classify(t: Trigger, nxt: int, now: int, p: Policy): Result
    requires Wf(t)

  // L1 next-sound: whenever the next occurrence after a time is reported, it is strictly later than that
  // time and it is a real occurrence of the trigger (the anchor plus a whole number of periods, or the
  // once-time itself).
  lemma L1NextSound(t: Trigger, after: int)
    requires Wf(t) && Next(t, after).Some?
    ensures Next(t, after).v > after && Occ(t, Next(t, after).v)

  // L2 next-minimal: no occurrence is ever skipped: for any real occurrence later than the given time, a
  // next occurrence is reported and it is no later than that one.
  lemma L2NextMinimal(t: Trigger, after: int, x: int)
    requires Wf(t) && Occ(t, x) && x > after
    ensures Next(t, after).Some? && Next(t, after).v <= x

  // L3 next-none: "no next occurrence" is reported exactly when the trigger is a one-shot whose time is
  // at or before the given time; an interval trigger always has a next occurrence.
  lemma L3NextNone(t: Trigger, after: int)
    requires Wf(t)
    ensures Next(t, after).None? <==> (t.Once? && t.at <= after)

  // L4 first-interval: for an interval trigger, the first occurrence at creation time `now` is a real
  // occurrence at or after now, and no real occurrence at or after now comes before it.
  lemma L4FirstInterval(t: Trigger, now: int)
    requires Wf(t) && t.Interval?
    ensures var f := First(t, now);
      f.Some? && f.v >= now && Occ(t, f.v) && forall x: int | Occ(t, x) && x >= now :: f.v <= x

  // L5 classify-not-due: if the stored next occurrence is still in the future, nothing is dispatched or
  // skipped and the stored next occurrence is kept unchanged.
  lemma L5ClassifyNotDue(t: Trigger, nxt: int, now: int, p: Policy)
    requires Wf(t) && nxt > now
    ensures Classify(t, nxt, now, p) == Result(None, Some(nxt), None)

  // L6 classify-due: if the stored next occurrence is real and due (at or before now), exactly one
  // occurrence is acted on: dispatched under the "latest" policy, skipped under "skip". It is the latest
  // occurrence that is due (a Witness), and the new stored next occurrence is the first one after now for
  // an interval trigger, or none for a one-shot.
  lemma L6ClassifyDue(t: Trigger, nxt: int, now: int, p: Policy)
    requires Wf(t) && Occ(t, nxt) && nxt <= now
    ensures var d := Classify(t, nxt, now, p);
      (d.dispatchAt.Some? != d.skipped.Some?)
      && (d.dispatchAt.Some? <==> p == Latest)
      && (d.dispatchAt.Some? ==> Witness(t, nxt, now, d.dispatchAt.v))
      && (d.skipped.Some? ==> Witness(t, nxt, now, d.skipped.v))
      && (if t.Interval? then d.next == Next(t, now) else d.next == None)

  // L7 first-once: for a one-shot trigger the first occurrence is always its own time, even when that
  // time is already in the past (the scheduler then dispatches or skips it).
  lemma L7FirstOnce(at: int, now: int)
    ensures First(Once(at), now) == Some(at)

  // L8 first-every-ms: for an interval trigger whose period is 1 ms, every millisecond from the anchor on
  // is an occurrence, so the first occurrence at a creation time at or after the anchor is that time
  // itself (never a millisecond earlier or later).
  lemma L8FirstEveryMs(a: int, now: int)
    requires now >= a
    ensures First(Interval(a, 1), now) == Some(now)
}
