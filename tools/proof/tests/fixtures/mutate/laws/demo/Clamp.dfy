// Laws of the fixture block demo/clamp (test input for tools/proof/tests; not a core block).
abstract module ClampLaws {
  function Clamp(lo: int, hi: int, x: int): int
    requires lo <= hi

  // L1 in-range: the result is never outside [lo, hi].
  lemma L1InRange(lo: int, hi: int, x: int)
    requires lo <= hi
    ensures lo <= Clamp(lo, hi, x) <= hi

  // L2 inside: a value already inside [lo, hi] is returned unchanged.
  lemma L2Inside(lo: int, hi: int, x: int)
    requires lo <= x <= hi
    ensures Clamp(lo, hi, x) == x

  // L3 below: a value below lo becomes lo.
  lemma L3Below(lo: int, hi: int, x: int)
    requires lo <= hi && x < lo
    ensures Clamp(lo, hi, x) == lo

  // L4 above: a value above hi becomes hi.
  lemma L4Above(lo: int, hi: int, x: int)
    requires lo <= hi && hi < x
    ensures Clamp(lo, hi, x) == hi

  // Supporting lemma: the inside case restated at the lower edge.
  lemma AtLow(lo: int, hi: int)
    requires lo <= hi
    ensures Clamp(lo, hi, lo) == lo
}
