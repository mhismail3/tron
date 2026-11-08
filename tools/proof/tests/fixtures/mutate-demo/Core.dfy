// Slice S1 (schedule): pure integer-ms core of nextAutomationOccurrence / firstAutomationOccurrence /
// classifyDueOccurrence from slices/schedule/schedule.ts. Calendar triggers are out of scope.
module Core {
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

  // ---------- the oracle functions ----------

  function Next(t: Trigger, after: int): Opt
    requires Wf(t)
  {
    match t
    case Once(at) => if at > after then Some(at) else None
    case Interval(a, e) =>
      if after < a then Some(a) else Some(a + ((after - a) / e + 1) * e)
  }

  function First(t: Trigger, now: int): Opt
    requires Wf(t)
  {
    match t
    case Once(at) => Some(at)
    // The first occurrence at or after now is the next one after now - 1 (this already yields the anchor
    // when a >= now; a separate `a >= now` branch was redundant, shown by mutation testing).
    case Interval(a, e) => Next(t, now - 1)
  }

  function Classify(t: Trigger, nxt: int, now: int, p: Policy): Result
    requires Wf(t)
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
}
