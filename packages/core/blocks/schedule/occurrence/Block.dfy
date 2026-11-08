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

  // ---------- definitions (compiled to JS) ----------

  function Next(t: Trigger, after: int): Opt
  {
    match t
    case Once(at) => if at > after then Some(at) else None
    case Interval(a, e) =>
      if after < a then Some(a) else Some(a + ((after - a) / e + 1) * e)
  }

  function First(t: Trigger, now: int): Opt
  {
    match t
    case Once(at) => Some(at)
    // The first occurrence at or after now is the next one after now - 1; this already yields the anchor
    // when a >= now.
    case Interval(a, e) => Next(t, now - 1)
  }

  function Classify(t: Trigger, nxt: int, now: int, p: Policy): Result
  {
    if nxt > now then Result(None, Some(nxt), None)
    else match t
    case Once(at) =>
      if p == Latest then Result(Some(nxt), None, None) else Result(None, None, Some(nxt))
    case Interval(a, e) =>
      var q := (now - nxt) / e;
      var latest := nxt + q * e;
      var n2 := nxt + (q + 1) * e;
      if p == Skip then Result(None, Some(n2), Some(latest))
      else Result(Some(latest), Some(n2), None)
  }

  // ---------- proofs ----------

  // The anchor plus any whole number of periods is an occurrence.
  lemma OccInterval(a: int, e: int, k: nat)
    ensures Occ(Interval(a, e), a + k * e)
  {}

  lemma L1NextSound(t: Trigger, after: int)
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

  lemma L2NextMinimal(t: Trigger, after: int, x: int)
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

  lemma L3NextNone(t: Trigger, after: int)
  {}

  lemma L4FirstInterval(t: Trigger, now: int)
  {
    // First(t, now) is the next occurrence after now - 1: sound by L1, minimal by L2.
    L1NextSound(t, now - 1);
    forall x: int | Occ(t, x) && x >= now ensures First(t, now).v <= x {
      L2NextMinimal(t, now - 1, x);
    }
  }

  lemma L8FirstAfterOccurrence(a: int, e: int, k: nat)
  {
    // First is the next occurrence after a + k*e, and (k*e)/e == k.
    MulNonNeg(k, e);
    ShiftDiv(0, k, e);
    assert (a + k * e - a) / e == k;
  }

  lemma L7FirstOnce(at: int, now: int)
  {}

  lemma L5ClassifyNotDue(t: Trigger, nxt: int, now: int, p: Policy)
  {}

  lemma L6ClassifyDue(t: Trigger, nxt: int, now: int, p: Policy)
  {
    match t {
      case Once(at) => {}
      case Interval(a, e) =>
        var j: nat :| nxt == a + j * e;
        L6IntervalResult(t, nxt, now, p);
        L6IntervalLatest(a, e, j, now);
        L6IntervalNext(a, e, j, now);
        L1NextSound(t, now);
    }
  }

  // Proof helpers for L6 (Interval case), split so each obligation stays small and solver-portable.
  // Classify's due interval result in named terms: the latest due occurrence nxt + q*e and the next nxt + (q+1)*e.
  lemma L6IntervalResult(t: Trigger, nxt: int, now: int, p: Policy)
    requires t.Interval? && t.every > 0 && nxt <= now
    ensures var q := (now - nxt) / t.every;
      Classify(t, nxt, now, p) == if p == Skip then Result(None, Some(nxt + (q + 1) * t.every), Some(nxt + q * t.every))
        else Result(Some(nxt + q * t.every), Some(nxt + (q + 1) * t.every), None)
  {}

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
