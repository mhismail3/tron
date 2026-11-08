// Proofs of the fixture block arith/divide.
include "../../../laws/arith/Divide.dfy"
module Divide refines DivideLaws {
  lemma DivFacts(y: int, e: int) returns (q: int) { q := y / e; }
  lemma MulAtLeast(d: int, e: int)
    requires d >= 1 && e > 0
    ensures d * e >= e
    decreases d
  { if d > 1 { MulAtLeast(d - 1, e); assert d * e == (d - 1) * e + e; } }
  lemma MulMono(i: int, j: int, e: int)
  { assert j * e - i * e == (j - i) * e; MulAtLeast(j - i, e); }
}
