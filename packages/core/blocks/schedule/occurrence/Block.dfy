// Block schedule/occurrence: definitions and proofs of laws/schedule/Occurrence.dfy.
include "../../../laws/schedule/Occurrence.dfy"

module ScheduleOccurrence refines ScheduleOccurrenceLaws {
  // ---------- arithmetic helpers (ghost; erased at compile time) ----------

  // Euclidean division: for e > 0, `/` and `%` are floor division and its remainder.
  lemma DivMod(x: int, e: int)
    requires e > 0
    ensures e * (x / e) + x % e == x
    ensures 0 <= x % e < e
  {}

  lemma MulNonNeg(d: int, e: int)
    requires d >= 0 && e >= 0
    ensures d * e >= 0
    decreases d
  { if d > 0 { MulNonNeg(d - 1, e); assert d * e == (d - 1) * e + e; } }

  // e > 0, s <= q ==> s*e <= q*e
  lemma MulLeMono(s: int, q: int, e: int)
    requires e > 0 && s <= q
    ensures s * e <= q * e
  {
    MulNonNeg(q - s, e);
    assert (q - s) * e == q * e - s * e;
  }

  // x >= 0, e > 0 ==> x / e >= 0
  lemma DivNonNeg(x: int, e: int)
    requires x >= 0 && e > 0
    ensures x / e >= 0
  {
    DivMod(x, e);
    if x / e <= -1 {
      MulLeMono(x / e, -1, e);
    }
  }

  // Shifting the dividend by a whole number of periods shifts the quotient by the same count.
  lemma ShiftDiv(x: int, j: int, e: int)
    requires e > 0
    ensures (x + j * e) / e == x / e + j
  {
    DivMod(x, e);
    DivMod(x + j * e, e);
    var D := (x + j * e) / e - (x / e + j);
    assert e * D == x % e - (x + j * e) % e;
    if D >= 1 { MulLeMono(1, D, e); }
    if D <= -1 { MulLeMono(D, -1, e); }
  }

  // The whole periods in a span that is not negative are not negative, no more than the span, and together
  // no longer than it.
  lemma PeriodsFit(x: int, e: int)
    requires x >= 0 && e > 0
    ensures 0 <= x / e <= x && 0 <= (x / e) * e <= x
  {
    DivMod(x, e);
    DivNonNeg(x, e);
    MulNonNeg(x / e, e);
    if x / e > 0 { MulLeMono(1, e, x / e); }
  }

  // ---------- definitions (compiled to JS) ----------

  // The whole periods of e in a span that is not negative.
  function Periods(span: Ms, e: Ms): (q: Ms)
    requires 0 <= span <= 2 * LIMIT && 0 < e <= LIMIT
    ensures q as int == span as int / e as int && 0 <= q as int * e as int <= span as int
  {
    PeriodsFit(span as int, e as int);
    span / e
  }

  function Next(t: Trigger, after: Ms): Opt
  {
    match t
    case Once(at) => if at > after then Some(at) else None
    case Interval(a, e) => if after < a then Some(a) else Some(a + Periods(after - a, e) * e + e)
  }

  function First(t: Trigger, now: Ms): Opt
  {
    match t
    case Once(at) => Some(at)
    // The first occurrence at or after now is the anchor when it is not before now, else the next one after
    // now - 1.
    case Interval(a, e) => if now <= a then Some(a) else Next(t, now - 1)
  }

  function Classify(t: Trigger, nxt: Ms, now: Ms, p: Policy): Result
  {
    if nxt > now then Result(None, Some(nxt), None)
    else match t
    case Once(at) =>
      if p.Latest? then Result(Some(nxt), None, None) else Result(None, None, Some(nxt))
    case Interval(a, e) =>
      var latest := nxt + Periods(now - nxt, e) * e;
      if p.Skip? then Result(None, Some(latest + e), Some(latest))
      else Result(Some(latest), Some(latest + e), None)
  }

  // ---------- proofs ----------

  // The anchor plus any whole number of periods is an occurrence.
  lemma OccInterval(a: Ms, e: Ms, k: nat)
    ensures Occ(Interval(a, e), a as int + k * (e as int))
  {}

  lemma L1NextSound(t: Trigger, after: Ms)
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        if after < a {
          OccInterval(a, e, 0);
        } else {
          var span, ei := (after - a) as int, e as int;
          PeriodsFit(span, ei);
          DivMod(span, ei);
          var k: nat := span / ei + 1;
          assert k * ei == (span / ei) * ei + ei;
          assert Next(t, after).v as int == a as int + k * ei;
          OccInterval(a, e, k);
        }
    }
  }

  lemma L2NextMinimal(t: Trigger, after: Ms, x: int)
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        var k: nat :| x == a as int + k * (e as int);
        if after < a {
          MulNonNeg(k, e as int);
        } else {
          DivNonNeg((after - a) as int, e as int);
          DivMod((after - a) as int, e as int);
          var q := (after - a) as int / e as int;
          if k <= q {
            MulLeMono(k, q, e as int);
          } else {
            MulLeMono(q + 1, k, e as int);
          }
        }
    }
  }

  lemma L3NextNone(t: Trigger, after: Ms)
  {}

  lemma L4FirstInterval(t: Trigger, now: Ms)
  {
    var a, e := t.anchor, t.every;
    if now <= a {
      OccInterval(a, e, 0);
      forall x: int | Occ(t, x) && x >= now as int ensures a as int <= x {
        var k: nat :| x == a as int + k * (e as int);
        MulNonNeg(k, e as int);
      }
    } else {
      // First(t, now) is the next occurrence after now - 1: sound by L1, minimal by L2.
      L1NextSound(t, now - 1);
      forall x: int | Occ(t, x) && x >= now as int ensures First(t, now).v as int <= x {
        L2NextMinimal(t, now - 1, x);
      }
    }
  }

  lemma L8FirstAfterOccurrence(a: Ms, e: Ms, k: nat)
  {
    // First is the next occurrence after a + k*e, and (k*e)/e == k.
    MulNonNeg(k, e as int);
    ShiftDiv(0, k, e as int);
    assert (a as int + k * (e as int) - a as int) / e as int == k;
  }

  lemma L7FirstOnce(at: Ms, now: Ms)
  {}

  lemma L5ClassifyNotDue(t: Trigger, nxt: Ms, now: Ms, p: Policy)
  {}

  lemma L6ClassifyDue(t: Trigger, nxt: Ms, now: Ms, p: Policy)
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        var j: nat :| nxt as int == a as int + j * (e as int);
        L6IntervalLatest(a, e, j, now);
        L6IntervalNext(a, e, j, now);
        L1NextSound(t, now);
    }
  }

  // Proof helpers for L6 (Interval case), split so each obligation stays small and solver-portable.
  // latest := nxt + q*e (q = (now - nxt)/e) is an occurrence in [nxt, now] with none in (latest, now].
  lemma L6IntervalLatest(a: Ms, e: Ms, j: nat, now: Ms)
    requires e > 0 && a as int + j * (e as int) <= now as int
    ensures var nxt := a as int + j * (e as int); var q := (now as int - nxt) / e as int;
      q >= 0 && Witness(Interval(a, e), nxt, now as int, nxt + q * (e as int))
  {
    var t := Interval(a, e);
    var nxt := a as int + j * (e as int);
    DivNonNeg(now as int - nxt, e as int);
    DivMod(now as int - nxt, e as int);
    var q := (now as int - nxt) / e as int;
    MulNonNeg(q, e as int);
    var m: nat := j + q;
    OccInterval(a, e, m);
    assert a as int + m * (e as int) == nxt + q * (e as int);
    forall x: int | Occ(t, x) && nxt + q * (e as int) < x <= now as int ensures false {
      var k: nat :| x == a as int + k * (e as int);
      NoOccBetween(a as int, e as int, j, k, q, now as int);
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

  // The next occurrence after now is one period after the latest due one: nxt + (q+1)*e.
  lemma L6IntervalNext(a: Ms, e: Ms, j: nat, now: Ms)
    requires Wf(Interval(a, e)) && InRange(now) && a as int + j * (e as int) <= now as int
    ensures var nxt := a as int + j * (e as int); var q := (now as int - nxt) / e as int;
      Next(Interval(a, e), now).Some? && Next(Interval(a, e), now).v as int == nxt + (q + 1) * (e as int)
  {
    var nxt := a as int + j * (e as int);
    var q := (now as int - nxt) / e as int;
    MulNonNeg(j, e as int);
    ShiftDiv(now as int - nxt, j, e as int);
    assert now as int - a as int == (now as int - nxt) + j * (e as int);
    assert (now as int - a as int) / e as int == q + j;
    assert a as int + ((now as int - a as int) / e as int + 1) * (e as int) == nxt + (q + 1) * (e as int);
  }
}
