// Copy of experiments/schedule/dafny/Laws.dfy WITHOUT L7 first-once;
// used only by tools/mutate/demo.sh to show that a false "equivalent" acceptance is rejected.
// Laws L1..L6 of experiments/schedule/SPEC.md, stated over Core and proved here.
include "Core.dfy"

module Laws {
  import opened Core

  // Witness: L is a real occurrence of the trigger between nxt and now (inclusive), and it is the latest
  // such occurrence: no occurrence falls after L and at or before now.
  ghost predicate Witness(t: Trigger, nxt: int, now: int, L: int) {
    Occ(t, L) && nxt <= L <= now && forall x: int | Occ(t, x) && L < x <= now :: false
  }

  lemma OccInterval(a: int, e: int, k: nat)
    ensures Occ(Interval(a, e), a + k * e)
  {}

  // L1 next-sound: whenever the next occurrence after a time is reported, it is strictly later than that
  // time and it is a real occurrence of the trigger (the anchor plus a whole number of periods, or the
  // once-time itself).
  lemma L1NextSound(t: Trigger, after: int)
    requires Wf(t) && Next(t, after).Some?
    ensures Next(t, after).v > after && Occ(t, Next(t, after).v)
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        if after < a {
          OccInterval(a, e, 0);
        } else {
          DivNonNeg(after - a, e);
          DivMod(after - a, e);
          var k: nat := (after - a) / e + 1;
          OccInterval(a, e, k);
        }
    }
  }

  // L2 next-minimal: no occurrence is ever skipped: for any real occurrence later than the given time, a
  // next occurrence is reported and it is no later than that one.
  lemma L2NextMinimal(t: Trigger, after: int, x: int)
    requires Wf(t) && Occ(t, x) && x > after
    ensures Next(t, after).Some? && Next(t, after).v <= x
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        if after < a {
          var k: nat :| x == a + k * e;
          MulNonNeg(k, e);
        } else {
          var k: nat :| x == a + k * e;
          DivNonNeg(after - a, e);
          DivMod(after - a, e);
          var q := (after - a) / e;
          if k <= q {
            MulLeMono(k, q, e);
          } else {
            MulLeMono(q + 1, k, e);
          }
        }
    }
  }

  // L3 next-none: "no next occurrence" is reported exactly when the trigger is a one-shot whose time is
  // at or before the given time; an interval trigger always has a next occurrence.
  lemma L3NextNone(t: Trigger, after: int)
    requires Wf(t)
    ensures Next(t, after).None? <==> (t.Once? && t.at <= after)
  {}

  // L4 first-interval: for an interval trigger, the first occurrence at creation time `now` is a real
  // occurrence at or after now, and no real occurrence at or after now comes before it.
  lemma L4FirstInterval(t: Trigger, now: int)
    requires Wf(t) && t.Interval?
    ensures var f := First(t, now);
      f.Some? && f.v >= now && Occ(t, f.v) && forall x: int | Occ(t, x) && x >= now :: f.v <= x
  {
    // First(t, now) is the next occurrence after now - 1: sound by L1, minimal by L2.
    L1NextSound(t, now - 1);
    forall x: int | Occ(t, x) && x >= now ensures First(t, now).v <= x {
      L2NextMinimal(t, now - 1, x);
    }
  }

  // L8 first-every-ms: for an interval trigger whose period is 1 ms, every millisecond from the anchor on
  // is an occurrence, so the first occurrence at a creation time at or after the anchor is that time
  // itself (never a millisecond earlier or later). Added 2026-11-07: mutation testing found that an
  // off-by-one in `first` was refuted by L4 only through a solver time-out, which never counts as a kill.
  lemma L8FirstEveryMs(a: int, now: int)
    requires now >= a
    ensures First(Interval(a, 1), now) == Some(now)
  {}

  // L5 classify-not-due: if the stored next occurrence is still in the future, nothing is dispatched or
  // skipped and the stored next occurrence is kept unchanged.
  lemma L5ClassifyNotDue(t: Trigger, nxt: int, now: int, p: Policy)
    requires Wf(t) && nxt > now
    ensures Classify(t, nxt, now, p) == Result(None, Some(nxt), None)
  {}

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
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        var j: nat :| nxt == a + j * e;
        L6IntervalLatest(a, e, j, now);
        L6IntervalNext(a, e, j, now);
    }
  }

  // Proof helpers for L6 (Interval case), split so each obligation stays small and solver-portable.
  // latest := nxt + q*e (q = (now - nxt)/e) is an occurrence in [nxt, now] with none in (latest, now].
  lemma L6IntervalLatest(a: int, e: int, j: nat, now: int)
    requires e > 0 && a + j * e <= now
    ensures var nxt := a + j * e; var q := (now - nxt) / e;
      q >= 0 && Witness(Interval(a, e), nxt, now, nxt + q * e)
  {
    var t := Interval(a, e);
    var nxt := a + j * e;
    DivNonNeg(now - nxt, e);
    DivMod(now - nxt, e);
    var q := (now - nxt) / e;
    MulNonNeg(q, e);
    var m: nat := j + q;
    OccInterval(a, e, m);
    assert a + m * e == nxt + q * e;
    forall x: int | Occ(t, x) && nxt + q * e < x <= now ensures false {
      var k: nat :| x == a + k * e;
      NoOccBetween(a, e, j, k, q, now);
    }
  }

  // No multiple of e lands strictly between nxt + q*e and nxt + (q+1)*e > now.
  lemma NoOccBetween(a: int, e: int, j: nat, k: nat, q: int, now: int)
    requires e > 0 && q == (now - (a + j * e)) / e && now - (a + j * e) >= 0
    requires a + j * e + q * e < a + k * e <= now
    ensures false
  {
    var nxt := a + j * e;
    DivMod(now - nxt, e);
    var s := k - j;
    assert (a + k * e) - nxt == s * e by { assert k * e - j * e == (k - j) * e; }
    if s <= q {
      MulLeMono(s, q, e);
    } else {
      MulLeMono(q + 1, s, e);
    }
  }

  // next(t, now) == nxt + (q+1)*e.
  lemma L6IntervalNext(a: int, e: int, j: nat, now: int)
    requires e > 0 && a + j * e <= now
    ensures var nxt := a + j * e; var q := (now - nxt) / e;
      Next(Interval(a, e), now) == Some(nxt + (q + 1) * e)
  {
    var nxt := a + j * e;
    var q := (now - nxt) / e;
    MulNonNeg(j, e);
    ShiftDiv(now - nxt, j, e);
    assert now - a == (now - nxt) + j * e;
    assert (now - a) / e == q + j;
    assert a + ((now - a) / e + 1) * e == nxt + (q + 1) * e;
  }
}
