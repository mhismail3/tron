// Definitions of the façade fixture block demo/meter.
include "../../../laws/demo/Meter.dfy"
module Meter refines MeterLaws {
  function Slot(at: Ms, every: Ms): Ms { at / every }
  function Compare(a: Reading, b: Reading): Trend {
    if a.level < b.level then Rising(b.level - a.level)
    else if b.level < a.level then Falling(a.level - b.level)
    else Flat
  }
  function Grain(s: Scale): Level { if s.Fine? then 1 else 10 }
  function LevelsOnto(readings: Chain<Reading>, levels: Chain<Level>): Chain<Level> {
    match readings
    case End => levels
    case Link(first, rest) => LevelsOnto(rest, Link(first.level, levels))
  }
  function Levels(s: Series): Chain<Level> { LevelsOnto(s.readings, End) }
  method Firsts(order: seq<Position>, taken: array<bool>) returns (firsts: Chain<Position>)
  {
    var n := |order| as Position;
    var k: Position := 0;
    while k < n invariant 0 <= k <= n { taken[k] := false; k := k + 1; }
    firsts := End;
    k := 0;
    while k < n invariant 0 <= k <= n
    {
      var p := order[k];
      if p < n && !taken[p] { taken[p] := true; firsts := Link(p, firsts); }
      k := k + 1;
    }
  }
}
