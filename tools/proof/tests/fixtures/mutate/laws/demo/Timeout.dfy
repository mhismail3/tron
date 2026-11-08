// Laws of the fixture block demo/timeout (test input for tools/proof/tests; not a core block).
abstract module TimeoutLaws {
  function F(x: int): int

  // T1 timeout-prone: vacuous while F(1) == 1; once a mutant changes F(1), its premise holds and the goal
  // (x^3 + y^3 != z^3, Fermat n = 3) is beyond the solver, so its proof runs out of resources.
  lemma T1(x: int, y: int, z: int)
    requires x > 0 && y > 0 && z > 0 && F(1) != 1
    ensures x * x * x + y * y * y != z * z * z
}
