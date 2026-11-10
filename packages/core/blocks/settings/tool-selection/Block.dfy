// Block settings/tool-selection: the linked-list functions the shell runs, and the proofs of
// laws/settings/ToolSelection.dfy.
include "../../../laws/settings/ToolSelection.dfy"

module SettingsToolSelection refines SettingsToolSelectionLaws {
  // ---------- definitions (compiled to JS) ----------
  // Every function here is tail-recursive, so it compiles to a loop and a list of any length is safe. A list is
  // built back to front in an accumulator and reversed at the end.

  // a reversed, then b.
  function RevOnto<T>(a: List<T>, b: List<T>): List<T> {
    match a
    case Nil => b
    case Cons(head, tail) => RevOnto(tail, Cons(head, b))
  }

  predicate Has(t: List<Token>, n: Token) {
    if t.Nil? then false else if t.head == n then true else Has(t.tail, n)
  }

  // acc reversed, then t without its first n.
  function WithoutFrom(t: List<Token>, n: Token, acc: List<Token>): List<Token> {
    if t.Nil? then RevOnto(acc, Nil)
    else if t.head == n then RevOnto(acc, t.tail)
    else WithoutFrom(t.tail, n, Cons(t.head, acc))
  }

  // The tools after one entry.
  function Step(tools: List<Token>, e: Entry): List<Token> {
    match e
    case Plain(_) => tools
    case Plus(n) => if n == 0 || Has(tools, n) then tools else RevOnto(RevOnto(tools, Nil), Cons(n, Nil))
    case Minus(n) => WithoutFrom(tools, n, Nil)
  }

  function ModsList(tools: List<Token>, entries: List<Entry>): List<Token>
    decreases entries
  {
    match entries
    case Nil => tools
    case Cons(e, rest) => ModsList(Step(tools, e), rest)
  }

  // acc reversed, then the plain names of es.
  function PlainsFrom(es: List<Entry>, acc: List<Token>): List<Token> {
    match es
    case Nil => RevOnto(acc, Nil)
    case Cons(e, rest) => PlainsFrom(rest, if e.Plain? then Cons(e.n, acc) else acc)
  }

  function ComposeList(below: BelowList, entries: List<Entry>, defaults: List<Token>): List<Token> {
    var plain := PlainsFrom(entries, Nil);
    if plain.Cons? || entries.Nil? then ModsList(plain, entries)
    else ModsList(if below.NamesList? then below.names else defaults, entries)
  }

  predicate HasModifier(es: List<Entry>) {
    if es.Nil? then false else if IsModifier(es.head) then true else HasModifier(es.tail)
  }

  predicate HasPlain(es: List<Entry>) {
    if es.Nil? then false else if es.head.Plain? then true else HasPlain(es.tail)
  }

  // An add (plus) or a remove of each name of a that is not in b, last name first, then acc.
  function MarksFrom(a: List<Token>, b: List<Token>, plus: bool, acc: List<Entry>): List<Entry> {
    if a.Nil? then acc
    else MarksFrom(a.tail, b, plus, if Has(b, a.head) then acc else Cons(if plus then Plus(a.head) else Minus(a.head), acc))
  }

  predicate Same(a: List<Token>, b: List<Token>) {
    if a.Nil? then b.Nil?
    else if b.Nil? then false
    else if a.head != b.head then false
    else Same(a.tail, b.tail)
  }

  // An add of each chosen name that is not in base, then a remove of each base name that is not chosen.
  function DeltaList(chosen: List<Token>, base: List<Token>): List<Entry> {
    RevOnto(MarksFrom(base, chosen, false, MarksFrom(chosen, base, true, Nil)), Nil)
  }

  function EncodeList(chosen: List<Entry>, below: BelowList, current: List<Entry>, defaults: List<Token>): HeldList {
    if HasModifier(chosen) then HoldsList(chosen)
    else if HasPlain(current) then HoldsList(chosen)
    else
      var base := if below.NamesList? then below.names else defaults;
      var names := PlainsFrom(chosen, Nil);
      var delta := DeltaList(names, base);
      if !Same(ModsList(base, delta), names) then HoldsList(chosen)
      else if delta.Cons? then HoldsList(delta) else NothingList
  }

  // ---------- proofs: the linked-list functions compute the sequence definitions ----------

  // Back: the items of a linked list, last first.
  ghost function Back<T>(l: List<T>): seq<T> {
    match l
    case Nil => []
    case Cons(head, tail) => Back(tail) + [head]
  }

  lemma RevOntoElems<T>(a: List<T>, b: List<T>)
    ensures Elems(RevOnto(a, b)) == Back(a) + Elems(b)
    ensures Back(RevOnto(a, b)) == Back(b) + Elems(a)
  {
    match a {
      case Nil => {}
      case Cons(head, tail) =>
        RevOntoElems(tail, Cons(head, b));
        assert Back(tail) + ([head] + Elems(b)) == (Back(tail) + [head]) + Elems(b);
        assert (Back(b) + [head]) + Elems(tail) == Back(b) + ([head] + Elems(tail));
    }
  }

  lemma HasSpec(t: List<Token>, n: Token)
    ensures Has(t, n) <==> n in Elems(t)
  { if t.Cons? { HasSpec(t.tail, n); } }

  lemma WithoutFromSpec(t: List<Token>, n: Token, acc: List<Token>)
    ensures Elems(WithoutFrom(t, n, acc)) == Back(acc) + RemoveFirst(Elems(t), n)
  {
    if t.Nil? {
      RevOntoElems(acc, Nil);
    } else {
      assert Elems(t)[0] == t.head && Elems(t)[1..] == Elems(t.tail);
      if t.head == n {
        RevOntoElems(acc, t.tail);
      } else {
        WithoutFromSpec(t.tail, n, Cons(t.head, acc));
        assert (Back(acc) + [t.head]) + RemoveFirst(Elems(t.tail), n) == Back(acc) + ([t.head] + RemoveFirst(Elems(t.tail), n));
      }
    }
  }

  // The tools after one entry, as Mods steps.
  ghost function StepSeq(tools: seq<Token>, e: Entry): seq<Token> {
    match e
    case Plain(_) => tools
    case Plus(n) => if n != 0 && n !in tools then tools + [n] else tools
    case Minus(n) => RemoveFirst(tools, n)
  }

  lemma StepSpec(tools: List<Token>, e: Entry)
    ensures Elems(Step(tools, e)) == StepSeq(Elems(tools), e)
  {
    match e {
      case Plain(_) => {}
      case Plus(n) =>
        HasSpec(tools, n);
        RevOntoElems(tools, Nil);
        RevOntoElems(RevOnto(tools, Nil), Cons(n, Nil));
        assert Elems(Cons(n, Nil)) == [n];
      case Minus(n) => WithoutFromSpec(tools, n, Nil);
    }
  }

  lemma ModsListSpec(tools: List<Token>, entries: List<Entry>)
    decreases entries
    ensures Elems(ModsList(tools, entries)) == Mods(Elems(tools), Elems(entries))
  {
    match entries {
      case Nil => {}
      case Cons(e, rest) =>
        assert Elems(entries)[0] == e && Elems(entries)[1..] == Elems(rest);
        StepSpec(tools, e);
        ModsListSpec(Step(tools, e), rest);
    }
  }

  lemma PlainsFromSpec(es: List<Entry>, acc: List<Token>)
    ensures Elems(PlainsFrom(es, acc)) == Back(acc) + Plains(Elems(es))
  {
    match es {
      case Nil => RevOntoElems(acc, Nil);
      case Cons(e, rest) =>
        assert Elems(es)[0] == e && Elems(es)[1..] == Elems(rest);
        PlainsFromSpec(rest, if e.Plain? then Cons(e.n, acc) else acc);
        if e.Plain? { assert (Back(acc) + [e.n]) + Plains(Elems(rest)) == Back(acc) + ([e.n] + Plains(Elems(rest))); }
    }
  }

  lemma L1ComposeComputed(below: BelowList, entries: List<Entry>, defaults: List<Token>)
  {
    PlainsFromSpec(entries, Nil);
    PlainsCount(Elems(entries));
    var plain := PlainsFrom(entries, Nil);
    assert Elems(plain) == Plains(Elems(entries));
    assert plain.Cons? <==> |Elems(plain)| > 0;
    assert entries.Nil? <==> |Elems(entries)| == 0;
    ModsListSpec(plain, entries);
    ModsListSpec(if below.NamesList? then below.names else defaults, entries);
  }

  // No more plain names than entries; as many exactly when every entry is plain, none exactly when every entry
  // is a modifier.
  lemma PlainsCount(es: seq<Entry>)
    decreases |es|
    ensures |Plains(es)| <= |es|
    ensures |Plains(es)| == |es| <==> forall i | 0 <= i < |es| :: es[i].Plain?
    ensures |Plains(es)| == 0 <==> AllModifiers(es)
  {
    if |es| > 0 {
      var rest := es[1..];
      PlainsCount(rest);
      if (forall i | 0 <= i < |rest| :: rest[i].Plain?) && es[0].Plain? {
        forall i | 0 <= i < |es| ensures es[i].Plain? { if i > 0 { assert es[i] == rest[i - 1]; } }
      }
      if forall i | 0 <= i < |es| :: es[i].Plain? {
        assert es[0].Plain?;
        forall i | 0 <= i < |rest| ensures rest[i].Plain? { assert rest[i] == es[i + 1]; }
      }
      if AllModifiers(rest) && IsModifier(es[0]) {
        forall i | 0 <= i < |es| ensures IsModifier(es[i]) { if i > 0 { assert es[i] == rest[i - 1]; } }
      }
      if AllModifiers(es) {
        assert IsModifier(es[0]);
        forall i | 0 <= i < |rest| ensures IsModifier(rest[i]) { assert rest[i] == es[i + 1]; }
      }
    }
  }

  // The entries hold a modifier exactly when they have fewer plain names than entries.
  lemma HoldsModifier(es: seq<Entry>)
    ensures (exists i | 0 <= i < |es| :: IsModifier(es[i])) <==> |Plains(es)| < |es|
  {
    PlainsCount(es);
    if exists i | 0 <= i < |es| :: IsModifier(es[i]) {
      var i :| 0 <= i < |es| && IsModifier(es[i]);
      assert !es[i].Plain?;
    }
    if !forall i | 0 <= i < |es| :: es[i].Plain? {
      var i :| 0 <= i < |es| && !es[i].Plain?;
      assert IsModifier(es[i]);
    }
  }

  lemma HasModifierSpec(es: List<Entry>)
    ensures HasModifier(es) <==> |Plains(Elems(es))| < |Elems(es)|
  {
    if es.Cons? {
      HasModifierSpec(es.tail);
      PlainsCount(Elems(es.tail));
      assert Elems(es)[0] == es.head && Elems(es)[1..] == Elems(es.tail);
    }
  }

  lemma HasPlainSpec(es: List<Entry>)
    ensures HasPlain(es) <==> |Plains(Elems(es))| > 0
  {
    if es.Cons? {
      HasPlainSpec(es.tail);
      assert Elems(es)[0] == es.head && Elems(es)[1..] == Elems(es.tail);
    }
  }

  // An add (plus) or a remove of each name, in order.
  ghost function Marked(names: seq<Token>, plus: bool): seq<Entry> {
    seq(|names|, i requires 0 <= i < |names| => if plus then Plus(names[i]) else Minus(names[i]))
  }

  lemma MarksFromSpec(a: List<Token>, b: List<Token>, plus: bool, acc: List<Entry>)
    ensures Back(MarksFrom(a, b, plus, acc)) == Back(acc) + Marked(Adds(Elems(a), Elems(b)), plus)
  {
    if a.Nil? {
      assert Marked([], plus) == [];
    } else {
      assert Elems(a)[0] == a.head && Elems(a)[1..] == Elems(a.tail);
      HasSpec(b, a.head);
      var rest := Adds(Elems(a.tail), Elems(b));
      var mark := if plus then Plus(a.head) else Minus(a.head);
      MarksFromSpec(a.tail, b, plus, if Has(b, a.head) then acc else Cons(mark, acc));
      if !Has(b, a.head) {
        assert Adds(Elems(a), Elems(b)) == [a.head] + rest;
        assert Marked([a.head] + rest, plus) == [mark] + Marked(rest, plus);
        assert (Back(acc) + [mark]) + Marked(rest, plus) == Back(acc) + ([mark] + Marked(rest, plus));
      } else {
        assert Adds(Elems(a), Elems(b)) == rest;
      }
    }
  }

  lemma SameSpec(a: List<Token>, b: List<Token>)
    ensures Same(a, b) <==> Elems(a) == Elems(b)
  {
    if a.Cons? && b.Cons? {
      SameSpec(a.tail, b.tail);
      assert Elems(a)[0] == a.head && Elems(a)[1..] == Elems(a.tail);
      assert Elems(b)[0] == b.head && Elems(b)[1..] == Elems(b.tail);
    } else if a.Cons? {
      assert |Elems(a)| > 0;
    } else if b.Cons? {
      assert |Elems(b)| > 0;
    }
  }

  lemma DeltaListSpec(chosen: List<Token>, base: List<Token>)
    ensures Elems(DeltaList(chosen, base)) == Delta(Elems(chosen), Elems(base))
  {
    var adds := MarksFrom(chosen, base, true, Nil);
    MarksFromSpec(chosen, base, true, Nil);
    var marks := MarksFrom(base, chosen, false, adds);
    MarksFromSpec(base, chosen, false, adds);
    RevOntoElems(marks, Nil);
    assert Elems(DeltaList(chosen, base)) == Marked(Adds(Elems(chosen), Elems(base)), true) + Marked(Adds(Elems(base), Elems(chosen)), false);
  }

  // What a layer holds, from the three facts Encode and EncodeList decide by.
  ghost function Decide(holdsModifier: bool, holdsPlain: bool, reproduced: bool, chosen: seq<Entry>, delta: seq<Entry>): Held {
    if holdsModifier || holdsPlain || !reproduced then Holds(chosen)
    else if |delta| > 0 then Holds(delta) else Nothing
  }

  // EncodeList decides by its own three facts.
  lemma EncodeListDecides(chosen: List<Entry>, below: BelowList, current: List<Entry>, defaults: List<Token>)
    ensures var base := if below.NamesList? then below.names else defaults;
      var names := PlainsFrom(chosen, Nil);
      var delta := DeltaList(names, base);
      HeldOf(EncodeList(chosen, below, current, defaults))
        == Decide(HasModifier(chosen), HasPlain(current), Same(ModsList(base, delta), names), Elems(chosen), Elems(delta))
  {}

  // Encode decides by the same three facts.
  lemma EncodeDecides(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    ensures var base := if below.Names? then below.names else defaults;
      var delta := Delta(Plains(chosen), base);
      Encode(chosen, below, current, defaults)
        == Decide(exists i | 0 <= i < |chosen| :: IsModifier(chosen[i]), !AllModifiers(current), Mods(base, delta) == Plains(chosen), chosen, delta)
  {}

  lemma L2EncodeComputed(chosen: List<Entry>, below: BelowList, current: List<Entry>, defaults: List<Token>)
  {
    EncodeListDecides(chosen, below, current, defaults);
    EncodeDecides(Elems(chosen), BelowOf(below), Elems(current), Elems(defaults));
    HasModifierSpec(chosen);
    HoldsModifier(Elems(chosen));
    HasPlainSpec(current);
    PlainsCount(Elems(current));
    var base := if below.NamesList? then below.names else defaults;
    var names := PlainsFrom(chosen, Nil);
    PlainsFromSpec(chosen, Nil);
    assert Elems(names) == Plains(Elems(chosen));
    var delta := DeltaList(names, base);
    DeltaListSpec(names, base);
    ModsListSpec(base, delta);
    SameSpec(ModsList(base, delta), names);
  }

  // ---------- proofs: what Compose and Encode do ----------

  lemma M1ModifierSteps(t: seq<Token>, n: Token)
  {
    assert [Plain(n)][1..] == [] && [Plus(n)][1..] == [] && [Minus(n)][1..] == [];
  }

  lemma M2ModifierSequence(t: seq<Token>, a: seq<Entry>, b: seq<Entry>)
  { ModsAppend(t, a, b); }

  // Mods over a concatenation, by induction on the first list.
  lemma ModsAppend(t: seq<Token>, a: seq<Entry>, b: seq<Entry>)
    decreases |a|
    ensures Mods(t, a + b) == Mods(Mods(t, a), b)
  {
    if |a| == 0 { assert a + b == b; }
    else {
      assert (a + b)[0] == a[0] && (a + b)[1..] == a[1..] + b;
      ModsAppend(StepSeq(t, a[0]), a[1..], b);
    }
  }

  // Plain entries change nothing.
  lemma ModsPlainId(t: seq<Token>, es: seq<Entry>)
    requires forall i | 0 <= i < |es| :: es[i].Plain?
    decreases |es|
    ensures Mods(t, es) == t
  { if |es| > 0 { ModsPlainId(t, es[1..]); } }

  lemma C1ModifiersOverBelow(below: seq<Token>, es: seq<Entry>, defaults: seq<Token>) {}

  lemma C2PlainList(below: Below, es: seq<Entry>, defaults: seq<Token>)
  { PlainsCount(es); }

  lemma C3ModifiersOverDefaults(es: seq<Entry>, defaults: seq<Token>)
  { PlainsCount(es); }

  lemma C4EmptyIsNoTools(below: Below, defaults: seq<Token>) {}

  lemma RemoveFirstSubset(t: seq<Token>, n: Token)
    decreases |t|
    ensures forall x | x in RemoveFirst(t, n) :: x in t
    ensures Nodup(t) ==> Nodup(RemoveFirst(t, n))
  {
    if |t| > 0 && t[0] != n {
      RemoveFirstSubset(t[1..], n);
      var w := RemoveFirst(t[1..], n);
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
  lemma ModsNodup(t: seq<Token>, es: seq<Entry>)
    requires Nodup(t)
    decreases |es|
    ensures Nodup(Mods(t, es))
  {
    if |es| > 0 {
      if es[0].Minus? { RemoveFirstSubset(t, es[0].n); }
      assert Nodup(StepSeq(t, es[0]));
      ModsNodup(StepSeq(t, es[0]), es[1..]);
    }
  }

  lemma B1NoDuplicates(below: Below, es: seq<Entry>, defaults: seq<Token>)
  {
    var start := if below.Names? && |es| > 0 && AllModifiers(es) then below.names
      else if |Plains(es)| > 0 || |es| == 0 then Plains(es) else defaults;
    ModsNodup(start, es);
  }

  lemma E1ModifiersKept(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>) {}

  lemma E2PlainStaysPlain(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
  {
    var i :| 0 <= i < |current| && current[i].Plain?;
    assert !AllModifiers(current);
  }

  // A choice of plain names composes back to itself.
  lemma ComposeChosen(below: Below, chosen: seq<Entry>, defaults: seq<Token>)
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

  lemma E3RoundTrip(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
  {
    var base := if below.Names? then below.names else defaults;
    ComposeChosen(below, chosen, defaults);
    var d := Delta(Plains(chosen), base);
    assert AllModifiers(d);
    if |d| > 0 && !below.Names? { C3ModifiersOverDefaults(d, defaults); }
  }

  lemma E4RelativeWhenReproducible(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>) {}

  lemma E5PlainWhenOrderDiffers(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>) {}
}
