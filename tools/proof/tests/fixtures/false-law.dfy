// Must fail under the pinned toolchain: the postcondition is false for a < b.
method Max(a: int, b: int) returns (m: int)
  ensures m == a
{
  if a >= b { m := a; } else { m := b; }
}
