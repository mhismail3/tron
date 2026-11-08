// Definition and proofs of the fixture block demo/clamp.
include "../../../laws/demo/Clamp.dfy"
module Clamp refines ClampLaws {
  function Clamp(lo: int, hi: int, x: int): int
  {
    if x < lo then lo else if hi < x then hi else x
  }
  lemma L1InRange(lo: int, hi: int, x: int) {}
  lemma L2Inside(lo: int, hi: int, x: int) {}
  lemma L3Below(lo: int, hi: int, x: int) {}
  lemma L4Above(lo: int, hi: int, x: int) {}
  lemma AtLow(lo: int, hi: int) {}
}
