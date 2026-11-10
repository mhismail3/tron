// Definitions of the façade fixture block demo/meter.
include "../../../laws/demo/Meter.dfy"
module Meter refines MeterLaws {
  function Slot(at: Ms, every: Ms): Ms { at / every }
  function Compare(a: Reading, b: Reading): Trend {
    if a.level < b.level then Rising(b.level - a.level)
    else if b.level < a.level then Falling(a.level - b.level)
    else Flat
  }
  function LevelsOnto(readings: Chain<Reading>, levels: Chain<Level>): Chain<Level> {
    match readings
    case End => levels
    case Link(first, rest) => LevelsOnto(rest, Link(first.level, levels))
  }
  function Levels(s: Series): Chain<Level> { LevelsOnto(s.readings, End) }
}
