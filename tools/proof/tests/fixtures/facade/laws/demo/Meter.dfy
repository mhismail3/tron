// Laws of the façade fixture block demo/meter (test input for tools/proof/tests/facade.test.mjs; not a core
// block): a block a shell runs, so it compiles without the Dafny runtime. One declaration per form such a
// block's façade must carry.
abstract module MeterLaws {
  newtype Ms = x: int | -0x20_0000_0000_0000 < x < 0x20_0000_0000_0000
  newtype Level = x: int | 0 <= x <= 100
  datatype Reading = Reading(at: Ms, level: Level)
  datatype Trend = Rising(step: Level) | Falling(step: Level) | Flat
  // A linked list: the form in which such a block reads and builds lists.
  datatype Chain<T> = End | Link(first: T, rest: Chain<T>)
  datatype Series = Series(name: Level, readings: Chain<Reading>)

  // Recent: a time within a second of zero.
  predicate Recent(at: Ms) { -1000 < at < 1000 }

  // Period: a period of 1 to 999 ms.
  predicate Period(every: Ms) { 0 < every < 1000 }

  // The whole periods before a time (negative before zero).
  function Slot(at: Ms, every: Ms): Ms
    requires Recent(at) && Period(every)

  function Compare(a: Reading, b: Reading): Trend

  // The levels of a series, latest reading first.
  function Levels(s: Series): Chain<Level>
}
