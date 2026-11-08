// Laws of the fixture block arith/divide: statements only; dependents see nothing else.
abstract module DivideLaws {
  lemma DivFacts(y: int, e: int) returns (q: int)
    requires y >= 0 && e > 0
    ensures q == y / e && q >= 0 && q * e <= y < q * e + e
  lemma MulMono(i: int, j: int, e: int)
    requires e > 0 && i < j
    ensures i * e + e <= j * e
}
