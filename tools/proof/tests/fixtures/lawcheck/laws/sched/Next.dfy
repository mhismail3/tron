// Laws of the fixture block sched/next; proven from arith/divide's laws only.
include "../arith/Divide.dfy"
abstract module NextLaws {
  import A : DivideLaws
  function Next(anchor: int, every: int, after: int): int
    requires every > 0
  { if after < anchor then anchor else anchor + ((after - anchor) / every + 1) * every }
  lemma NextAfter(anchor: int, every: int, after: int)
    requires every > 0
    ensures Next(anchor, every, after) > after
}
