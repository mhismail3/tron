// Laws of the façade fixture block demo/counter (test input for tools/proof/tests/facade.test.mjs; not a
// core block): one declaration per form the façade generator must read.
abstract module CounterLaws {
  datatype Color =
    | Red
    | Green
    | Blue
  datatype Box = Box(count: nat, color: Color)
  datatype Step = Inc(amount: nat) | Reset

  /* function Old(x: int): int */

  // A box is valid while its count is at most 100.
  predicate Valid(b: Box) { b.count <= 100 }

  ghost function Twice(n: int): int { 2 * n }

  opaque function Apply(b: Box, s: Step): Box
    requires Valid(b)

  function Shade(c: Color): Color

  function Delta(a: int, b: int): int
}
