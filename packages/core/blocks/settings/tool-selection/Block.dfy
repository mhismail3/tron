// Block settings/tool-selection: definitions and proofs of laws/settings/ToolSelection.dfy.
include "../../../laws/settings/ToolSelection.dfy"

module SettingsToolSelection refines SettingsToolSelectionLaws {
  // ---------- definitions (compiled to JS) ----------

  // The list without the first occurrence of n.
  function Without(t: seq<int>, n: int): seq<int>
    decreases |t|
  { if |t| == 0 then [] else if t[0] == n then t[1..] else [t[0]] + Without(t[1..], n) }

  function Mods(tools: seq<int>, entries: seq<Entry>): seq<int>
  {
    if |entries| == 0 then tools
    else
      var e := entries[0];
      var next := match e
        case Plain(_) => tools
        case Plus(n) => if n != 0 && n !in tools then tools + [n] else tools
        case Minus(n) => Without(tools, n);
      Mods(next, entries[1..])
  }

  // The plain names of entries, in order.
  function PlainNames(es: seq<Entry>): seq<int>
    decreases |es|
  { if |es| == 0 then [] else (if es[0].Plain? then [es[0].n] else []) + PlainNames(es[1..]) }

  predicate AllModifiers(es: seq<Entry>) { forall i | 0 <= i < |es| :: IsModifier(es[i]) }

  function Compose(below: Below, entries: seq<Entry>, defaults: seq<int>): seq<int> {
    if below.Names? && |entries| > 0 && AllModifiers(entries) then Mods(below.names, entries)
    else
      var plain := PlainNames(entries);
      Mods(if |plain| > 0 || |entries| == 0 then plain else defaults, entries)
  }

  // The names of a not in b, in a's order.
  function Missing(a: seq<int>, b: seq<int>): seq<int>
    decreases |a|
  { if |a| == 0 then [] else (if a[0] in b then [] else [a[0]]) + Missing(a[1..], b) }

  function Encode(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>): Held {
    if exists i | 0 <= i < |chosen| :: IsModifier(chosen[i]) then Holds(chosen)
    else if !AllModifiers(current) then Holds(chosen)
    else
      var base := if below.Names? then below.names else defaults;
      var names := PlainNames(chosen);
      var adds := Missing(names, base);
      var removes := Missing(base, names);
      var entries := seq(|adds|, i requires 0 <= i < |adds| => Plus(adds[i]))
        + seq(|removes|, i requires 0 <= i < |removes| => Minus(removes[i]));
      if Mods(base, entries) != names then Holds(chosen)
      else if |entries| > 0 then Holds(entries) else Nothing
  }

  // ---------- proofs ----------

  lemma PlainNamesSpec(es: seq<Entry>)
    decreases |es|
    ensures PlainNames(es) == Plains(es)
  { if |es| > 0 { PlainNamesSpec(es[1..]); } }

  lemma WithoutSpec(t: seq<int>, n: int)
    decreases |t|
    ensures Without(t, n) == RemoveFirst(t, n)
  { if |t| > 0 { WithoutSpec(t[1..], n); } }

  lemma MissingSpec(a: seq<int>, b: seq<int>)
    decreases |a|
    ensures Missing(a, b) == Adds(a, b)
  { if |a| > 0 { MissingSpec(a[1..], b); } }

  lemma M1ModifierSteps(t: seq<int>, n: int)
  {
    assert [Plain(n)][1..] == [] && [Plus(n)][1..] == [] && [Minus(n)][1..] == [];
    WithoutSpec(t, n);
  }

  lemma M2ModifierSequence(t: seq<int>, a: seq<Entry>, b: seq<Entry>)
  { ModsAppend(t, a, b); }

  // Mods over a concatenation, by induction on the first list.
  lemma ModsAppend(t: seq<int>, a: seq<Entry>, b: seq<Entry>)
    decreases |a|
    ensures Mods(t, a + b) == Mods(Mods(t, a), b)
  {
    if |a| == 0 { assert a + b == b; }
    else {
      assert (a + b)[0] == a[0] && (a + b)[1..] == a[1..] + b;
      var next := match a[0]
        case Plain(_) => t
        case Plus(n) => if n != 0 && n !in t then t + [n] else t
        case Minus(n) => Without(t, n);
      ModsAppend(next, a[1..], b);
    }
  }

  // A list of only modifiers has no plain name; a list with a plain entry has one.
  lemma PlainNamesEmpty(es: seq<Entry>)
    decreases |es|
    ensures |PlainNames(es)| == 0 <==> AllModifiers(es)
  {
    if |es| > 0 {
      PlainNamesEmpty(es[1..]);
      if AllModifiers(es[1..]) && IsModifier(es[0]) {
        forall i | 0 <= i < |es| ensures IsModifier(es[i]) { if i > 0 { assert es[i] == es[1..][i - 1]; } }
      }
      if AllModifiers(es) { assert IsModifier(es[0]); assert forall i | 0 <= i < |es[1..]| :: es[1..][i] == es[i + 1]; }
    }
  }

  // Plain entries change nothing.
  lemma ModsPlainId(t: seq<int>, es: seq<Entry>)
    requires forall i | 0 <= i < |es| :: es[i].Plain?
    decreases |es|
    ensures Mods(t, es) == t
  { if |es| > 0 { ModsPlainId(t, es[1..]); } }

  lemma C1ModifiersOverBelow(below: seq<int>, es: seq<Entry>, defaults: seq<int>) {}

  lemma C2PlainList(below: Below, es: seq<Entry>, defaults: seq<int>)
  {
    PlainNamesEmpty(es);
    PlainNamesSpec(es);
  }

  lemma C3ModifiersOverDefaults(es: seq<Entry>, defaults: seq<int>)
  { PlainNamesEmpty(es); }

  lemma C4EmptyIsNoTools(below: Below, defaults: seq<int>) {}
  lemma WithoutSubset(t: seq<int>, n: int)
    decreases |t|
    ensures forall x | x in Without(t, n) :: x in t
    ensures Nodup(t) ==> Nodup(Without(t, n))
  {
    if |t| > 0 && t[0] != n {
      WithoutSubset(t[1..], n);
      var w := Without(t[1..], n);
      if Nodup(t) {
        assert Nodup(t[1..]) by { forall i, j | 0 <= i < j < |t[1..]| ensures t[1..][i] != t[1..][j] { assert t[1..][i] == t[i + 1] && t[1..][j] == t[j + 1]; } }
        assert t[0] !in t[1..] by { forall i | 0 <= i < |t[1..]| ensures t[1..][i] != t[0] { assert t[1..][i] == t[i + 1]; } }
        assert t[0] !in w;
      }
    } else if |t| > 0 && Nodup(t) {
      forall i, j | 0 <= i < j < |t[1..]| ensures t[1..][i] != t[1..][j] { assert t[1..][i] == t[i + 1] && t[1..][j] == t[j + 1]; }
    }
  }

  // Applying modifiers keeps a list free of repeats.
  lemma ModsNodup(t: seq<int>, es: seq<Entry>)
    requires Nodup(t)
    decreases |es|
    ensures Nodup(Mods(t, es))
  {
    if |es| > 0 {
      var next := match es[0]
        case Plain(_) => t
        case Plus(n) => if n != 0 && n !in t then t + [n] else t
        case Minus(n) => Without(t, n);
      match es[0] {
        case Plain(_) => {}
        case Plus(n) => {}
        case Minus(n) => WithoutSubset(t, n);
      }
      assert Nodup(next);
      ModsNodup(next, es[1..]);
    }
  }

  lemma B1NoDuplicates(below: Below, es: seq<Entry>, defaults: seq<int>)
  {
    PlainNamesSpec(es);
    var start := if below.Names? && |es| > 0 && AllModifiers(es) then below.names
      else if |PlainNames(es)| > 0 || |es| == 0 then PlainNames(es) else defaults;
    ModsNodup(start, es);
  }

  lemma E1ModifiersKept(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>) {}

  lemma E2PlainStaysPlain(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
  {
    var i :| 0 <= i < |current| && current[i].Plain?;
    assert !AllModifiers(current);
  }

  // The relative entries Encode builds are Delta, and hold only modifiers.
  lemma EncodeEntries(chosen: seq<Entry>, base: seq<int>)
    ensures var names := PlainNames(chosen);
      var adds := Missing(names, base);
      var removes := Missing(base, names);
      var entries := seq(|adds|, i requires 0 <= i < |adds| => Plus(adds[i]))
        + seq(|removes|, i requires 0 <= i < |removes| => Minus(removes[i]));
      entries == Delta(Plains(chosen), base) && AllModifiers(entries)
  {
    PlainNamesSpec(chosen);
    MissingSpec(PlainNames(chosen), base);
    MissingSpec(base, PlainNames(chosen));
  }

  // A choice of plain names composes back to itself.
  lemma ComposeChosen(below: Below, chosen: seq<Entry>, defaults: seq<int>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    ensures Compose(below, chosen, defaults) == Plains(chosen)
  {
    if |chosen| == 0 { C4EmptyIsNoTools(below, defaults); }
    else {
      assert chosen[0].Plain?;
      C2PlainList(below, chosen, defaults);
      ModsPlainId(Plains(chosen), chosen);
    }
  }

  lemma E3RoundTrip(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
  {
    var base := if below.Names? then below.names else defaults;
    EncodeEntries(chosen, base);
    PlainNamesSpec(chosen);
    ComposeChosen(below, chosen, defaults);
    var d := Delta(Plains(chosen), base);
    if |d| > 0 && !below.Names? { C3ModifiersOverDefaults(d, defaults); }
  }

  lemma E4RelativeWhenReproducible(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
  {
    var base := if below.Names? then below.names else defaults;
    EncodeEntries(chosen, base);
    PlainNamesSpec(chosen);
  }

  lemma E5PlainWhenOrderDiffers(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
  {
    var base := if below.Names? then below.names else defaults;
    EncodeEntries(chosen, base);
    PlainNamesSpec(chosen);
  }
}
