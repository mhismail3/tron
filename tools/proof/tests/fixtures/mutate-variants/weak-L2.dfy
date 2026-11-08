// Test variant of the demo/clamp laws: L2 and its helper weakened, so a mutant survives.
// Laws of the fixture block demo/clamp (test input for tools/proof/tests; not a core block).
abstract module ClampLaws {
  function Clamp(lo: int, hi: int, x: int): int
    requires lo <= hi

  // L1 in-range: the result is never outside [lo, hi].
  lemma L1InRange(lo: int, hi: int, x: int)
    requires lo <= hi
    ensures lo <= Clamp(lo, hi, x) <= hi

  // L2 inside, WEAKENED (test variant): a value inside [lo, hi] stays inside, but may move.
  lemma L2Inside(lo: int, hi: int, x: int)
    requires lo <= x <= hi
    ensures lo <= Clamp(lo, hi, x) <= hi

  // L3 below: a value below lo becomes lo.
  lemma L3Below(lo: int, hi: int, x: int)
    requires lo <= hi && x < lo
    ensures Clamp(lo, hi, x) == lo

  // L4 above: a value above hi becomes hi.
  lemma L4Above(lo: int, hi: int, x: int)
    requires lo <= hi && hi < x
    ensures Clamp(lo, hi, x) == hi

  // Supporting lemma, WEAKENED (test variant): the lower edge stays in range.
  lemma AtLow(lo: int, hi: int)
    requires lo <= hi
    ensures lo <= Clamp(lo, hi, lo)
}
