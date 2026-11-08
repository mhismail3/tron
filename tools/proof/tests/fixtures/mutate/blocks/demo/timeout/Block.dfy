// Definition and proof of the fixture block demo/timeout.
include "../../../laws/demo/Timeout.dfy"
module Timeout refines TimeoutLaws {
  function F(x: int): int { x * 1 }
  lemma T1(x: int, y: int, z: int) {}
}
