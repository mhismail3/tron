// Definitions of the façade fixture block demo/counter.
include "../../../laws/demo/Counter.dfy"
module Counter refines CounterLaws {
  opaque function Apply(b: Box, s: Step): Box {
    match s
    case Inc(amount) => Box(b.count + amount, b.color)
    case Reset => Box(0, b.color)
  }
  function Shade(c: Color): Color {
    match c
    case Red => Green
    case Green => Blue
    case Blue => Red
  }
  function Delta(a: int, b: int): int { a - b }
  function Counts(bs: seq<Box>): seq<nat> { seq(|bs|, i requires 0 <= i < |bs| => bs[i].count) }
  function Echo(r: Run): Run { r }
}
