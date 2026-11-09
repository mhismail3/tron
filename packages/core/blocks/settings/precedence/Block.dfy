// Block settings/precedence: definitions and proofs of laws/settings/Precedence.dfy.
include "../../../laws/settings/Precedence.dfy"

module SettingsPrecedence refines SettingsPrecedenceLaws {
  // ---------- definitions (compiled to JS) ----------

  predicate Admitted(k: Key, l: Layer) {
    match l
    case Global => true
    case Home => k.sessionOverridable
    case Session => k.sessionOverridable
    case Project => k.projectSettable
  }

  // Layer l's shown entry, when it takes part.
  function ShownAt(k: Key, ls: Layers, l: Layer): seq<Shown> {
    var e := At(ls, l);
    if !e.inTarget || !e.bound || !Admitted(k, l) then []
    else if e.qualified.Some? then [Shown(l, true, e.qualified.v, e.applied)]
    else if e.unqualified.Some? then [Shown(l, false, e.unqualified.v, e.applied)]
    else []
  }

  // The applied shown entries folded over the value v from origin o.
  function Fold(k: Key, s: seq<Shown>, v: Value, o: Origin): (Value, Origin)
    decreases |s|
  {
    if |s| == 0 then (v, o)
    else if !s[0].applied then Fold(k, s[1..], v, o)
    else Fold(k, s[1..], if k.composes then Compose(v, s[0].token) else Tok(s[0].token), FromLayer(s[0].layer))
  }

  function Resolve(k: Key, ls: Layers): Resolution {
    var s := ShownAt(k, ls, Global) + ShownAt(k, ls, Home) + ShownAt(k, ls, Session) + ShownAt(k, ls, Project);
    var r := Fold(k, s, Default, FromDefault);
    Resolution(r.0, r.1, if |s| > 0 && !s[|s| - 1].applied then Unapplied(s[|s| - 1].layer) else AllApplied, s)
  }

  // Layer m's plain value, when it counts below layer l.
  function PlainBelow(k: Key, ls: Layers, m: Layer, l: Layer): seq<int> {
    var e := At(ls, m);
    if Rank(m) < Rank(l) && e.inTarget && e.bound && Admitted(k, m) && e.applied && e.unqualified.Some?
    then [e.unqualified.v] else []
  }

  // The tokens folded over v, lowest first.
  function FoldTokens(k: Key, ts: seq<int>, v: Value): Value
    decreases |ts|
  { if |ts| == 0 then v else FoldTokens(k, ts[1..], if k.composes then Compose(v, ts[0]) else Tok(ts[0])) }

  function Below(k: Key, ls: Layers, l: Layer): Value {
    FoldTokens(k, PlainBelow(k, ls, Global, l) + PlainBelow(k, ls, Home, l) + PlainBelow(k, ls, Session, l)
      + PlainBelow(k, ls, Project, l), Default)
  }

  // ---------- proofs ----------

  lemma S1Admission(k: Key) {}

  // The state after layer l: an applied layer that takes part sets the value and the origin.
  ghost function StepL(k: Key, ls: Layers, l: Layer, st: (Value, Origin)): (Value, Origin) {
    if Live(k, ls, l) then (Step(k, st.0, Token(At(ls, l))), FromLayer(l)) else st
  }

  // The value and origin after the four layers, lowest first.
  ghost function Steps(k: Key, ls: Layers): (Value, Origin) {
    StepL(k, ls, Project, StepL(k, ls, Session, StepL(k, ls, Home, StepL(k, ls, Global, (Default, FromDefault)))))
  }

  lemma ShownAtSpec(k: Key, ls: Layers, l: Layer)
    ensures ShownAt(k, ls, l) == if Visible(k, ls, l)
      then [Shown(l, At(ls, l).qualified.Some?, Token(At(ls, l)), At(ls, l).applied)] else []
  {}

  lemma FoldAppend(k: Key, a: seq<Shown>, b: seq<Shown>, v: Value, o: Origin)
    decreases |a|
    ensures Fold(k, a + b, v, o) == var r := Fold(k, a, v, o); Fold(k, b, r.0, r.1)
  {
    if |a| == 0 {
      assert a + b == b;
    } else {
      assert (a + b)[0] == a[0] && (a + b)[1..] == a[1..] + b;
      var v2 := if k.composes then Compose(v, a[0].token) else Tok(a[0].token);
      if a[0].applied { FoldAppend(k, a[1..], b, v2, FromLayer(a[0].layer)); }
      else { FoldAppend(k, a[1..], b, v, o); }
    }
  }

  lemma FoldOne(k: Key, ls: Layers, l: Layer, st: (Value, Origin))
    ensures Fold(k, ShownAt(k, ls, l), st.0, st.1) == StepL(k, ls, l, st)
  { ShownAtSpec(k, ls, l); }

  ghost function AllShown(k: Key, ls: Layers): seq<Shown> {
    ShownAt(k, ls, Global) + ShownAt(k, ls, Home) + ShownAt(k, ls, Session) + ShownAt(k, ls, Project)
  }

  lemma ResolveSteps(k: Key, ls: Layers)
    ensures Resolve(k, ls).shown == AllShown(k, ls)
    ensures (Resolve(k, ls).value, Resolve(k, ls).layer) == Steps(k, ls)
  {
    var g, h, s, p := ShownAt(k, ls, Global), ShownAt(k, ls, Home), ShownAt(k, ls, Session), ShownAt(k, ls, Project);
    var st0 := (Default, FromDefault);
    FoldAppend(k, g + h + s, p, st0.0, st0.1);
    FoldAppend(k, g + h, s, st0.0, st0.1);
    FoldAppend(k, g, h, st0.0, st0.1);
    var st1 := StepL(k, ls, Global, st0); FoldOne(k, ls, Global, st0);
    var st2 := StepL(k, ls, Home, st1); FoldOne(k, ls, Home, st1);
    var st3 := StepL(k, ls, Session, st2); FoldOne(k, ls, Session, st2);
    FoldOne(k, ls, Project, st3);
  }

  lemma R2Default(k: Key, ls: Layers)
  { ResolveSteps(k, ls); }

  lemma R1Winner(k: Key, ls: Layers, l: Layer)
  { ResolveSteps(k, ls); }

  lemma R4UntrustedInert(k: Key, ls: Layers, ls2: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    ResolveSteps(k, ls2);
    forall m: Layer ensures Live(k, ls, m) == Live(k, ls2, m) && (Live(k, ls, m) ==> Token(At(ls, m)) == Token(At(ls2, m))) {
      if m != l { assert At(ls2, m) == At(ls, m); }
    }
  }

  lemma R5HigherScopeWins(k: Key, ls: Layers, ls2: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    ResolveSteps(k, ls2);
    assert At(ls2, l) == At(ls, l);
    forall m: Layer | Rank(m) >= Rank(l) ensures Live(k, ls, m) == Live(k, ls2, m) && At(ls2, m) == At(ls, m) {}
  }
  lemma FoldedAppend(k: Key, v: Value, a: seq<int>, b: seq<int>)
    decreases |a|
    ensures Folded(k, v, a + b) == Folded(k, Folded(k, v, a), b)
  {
    if |a| == 0 { assert a + b == b; }
    else {
      assert (a + b)[0] == a[0] && (a + b)[1..] == a[1..] + b;
      FoldedAppend(k, Step(k, v, a[0]), a[1..], b);
    }
  }

  // One layer's tokens fold like its step.
  lemma FoldedLayer(k: Key, ls: Layers, l: Layer, v: Value)
    ensures Folded(k, v, if Live(k, ls, l) then [Token(At(ls, l))] else []) == StepL(k, ls, l, (v, FromDefault)).0
  {}

  lemma R3Compose(k: Key, ls: Layers)
  {
    ResolveSteps(k, ls);
    var g := if Live(k, ls, Global) then [Token(ls.global)] else [];
    var h := if Live(k, ls, Home) then [Token(ls.home)] else [];
    var se := if Live(k, ls, Session) then [Token(ls.session)] else [];
    var p := if Live(k, ls, Project) then [Token(ls.project)] else [];
    assert LiveTokens(k, ls) == g + h + se + p;
    FoldedAppend(k, Default, g + h + se, p);
    FoldedAppend(k, Default, g + h, se);
    FoldedAppend(k, Default, g, h);
    var v1 := Folded(k, Default, g); FoldedLayer(k, ls, Global, Default);
    var v2 := Folded(k, v1, h); FoldedLayer(k, ls, Home, v1);
    var v3 := Folded(k, v2, se); FoldedLayer(k, ls, Session, v2);
    FoldedLayer(k, ls, Project, v3);
  }

  lemma FoldTokensFolded(k: Key, ts: seq<int>, v: Value)
    decreases |ts|
    ensures FoldTokens(k, ts, v) == Folded(k, v, ts)
  { if |ts| > 0 { FoldTokensFolded(k, ts[1..], Step(k, v, ts[0])); } }

  lemma R8Below(k: Key, ls: Layers, l: Layer)
  {
    var ts := PlainBelow(k, ls, Global, l) + PlainBelow(k, ls, Home, l) + PlainBelow(k, ls, Session, l) + PlainBelow(k, ls, Project, l);
    assert ts == BelowTokens(k, ls, l);
    FoldTokensFolded(k, ts, Default);
  }
  ghost predicate Sorted(s: seq<Shown>) { forall i, j | 0 <= i < j < |s| :: Rank(s[i].layer) < Rank(s[j].layer) }
  ghost predicate RanksAtMost(s: seq<Shown>, r: int) { forall i | 0 <= i < |s| :: Rank(s[i].layer) <= r }

  // Appending layer l's entry to sorted entries all ranked below l keeps them sorted.
  lemma SortedAppend(k: Key, ls: Layers, a: seq<Shown>, l: Layer)
    requires Sorted(a) && RanksAtMost(a, Rank(l) - 1)
    ensures Sorted(a + ShownAt(k, ls, l)) && RanksAtMost(a + ShownAt(k, ls, l), Rank(l))
  { ShownAtSpec(k, ls, l); }

  // The shown entries are sorted lowest first.
  lemma AllShownSorted(k: Key, ls: Layers)
    ensures Sorted(AllShown(k, ls))
  {
    SortedAppend(k, ls, [], Global);
    assert [] + ShownAt(k, ls, Global) == ShownAt(k, ls, Global);
    SortedAppend(k, ls, ShownAt(k, ls, Global), Home);
    SortedAppend(k, ls, ShownAt(k, ls, Global) + ShownAt(k, ls, Home), Session);
    SortedAppend(k, ls, ShownAt(k, ls, Global) + ShownAt(k, ls, Home) + ShownAt(k, ls, Session), Project);
  }

  // x is its own layer's shown entry, from a layer that takes part.
  ghost predicate Faithful(k: Key, ls: Layers, x: Shown) {
    Visible(k, ls, x.layer)
    && x == Shown(x.layer, At(ls, x.layer).qualified.Some?, Token(At(ls, x.layer)), At(ls, x.layer).applied)
  }

  // Each shown entry is faithful.
  lemma AllShownSpec(k: Key, ls: Layers, x: Shown)
    requires x in AllShown(k, ls)
    ensures Faithful(k, ls, x)
  {
    ShownAtSpec(k, ls, Global); ShownAtSpec(k, ls, Home); ShownAtSpec(k, ls, Session); ShownAtSpec(k, ls, Project);
  }

  // Every layer that takes part is shown.
  lemma AllShownHas(k: Key, ls: Layers, l: Layer)
    requires Visible(k, ls, l)
    ensures exists i | 0 <= i < |AllShown(k, ls)| :: AllShown(k, ls)[i].layer == l
  {
    ShownAtSpec(k, ls, l);
    var x := Shown(l, At(ls, l).qualified.Some?, Token(At(ls, l)), At(ls, l).applied);
    assert x in ShownAt(k, ls, l);
    var s := AllShown(k, ls);
    assert x in s;
    var i :| 0 <= i < |s| && s[i] == x;
  }

  lemma AllShownFacts(k: Key, ls: Layers)
    ensures var s := AllShown(k, ls);
      Sorted(s) && (forall x | x in s :: Faithful(k, ls, x))
      && forall l: Layer :: Visible(k, ls, l) <==> exists i | 0 <= i < |s| :: s[i].layer == l
  {
    var s := AllShown(k, ls);
    AllShownSorted(k, ls);
    forall x | x in s ensures Faithful(k, ls, x) { AllShownSpec(k, ls, x); }
    forall l: Layer ensures Visible(k, ls, l) <==> exists i | 0 <= i < |s| :: s[i].layer == l {
      if Visible(k, ls, l) { AllShownHas(k, ls, l); }
      if exists i | 0 <= i < |s| :: s[i].layer == l {
        var i :| 0 <= i < |s| && s[i].layer == l;
        assert s[i] in s;
        AllShownSpec(k, ls, s[i]);
        assert Faithful(k, ls, s[i]);
      }
    }
  }

  lemma R6Shown(k: Key, ls: Layers)
  {
    ResolveSteps(k, ls);
    AllShownFacts(k, ls);
    var s := Resolve(k, ls).shown;
    forall i | 0 <= i < |s| ensures var e := At(ls, s[i].layer);
      Visible(k, ls, s[i].layer) && s[i].token == Token(e) && s[i].qualified == e.qualified.Some? && s[i].applied == e.applied
    { assert s[i] in s; }
  }

  // The resolution's origin is an applied layer that takes part, or the default.
  lemma OriginLive(k: Key, ls: Layers)
    ensures Steps(k, ls).1.FromLayer? ==> Live(k, ls, Steps(k, ls).1.l)
  {}

  lemma R7NotApplied(k: Key, ls: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    AllShownFacts(k, ls);
    OriginLive(k, ls);
    var s := Resolve(k, ls).shown;
    if Resolve(k, ls).notApplied == Unapplied(l) {
      var last := s[|s| - 1];
      assert last in s;
      forall m: Layer | Rank(m) > Rank(l) ensures !Visible(k, ls, m) {
        if Visible(k, ls, m) { var i :| 0 <= i < |s| && s[i].layer == m; }
      }
    }
    if Visible(k, ls, l) && !At(ls, l).applied && forall m: Layer | Rank(m) > Rank(l) :: !Visible(k, ls, m) {
      var i :| 0 <= i < |s| && s[i].layer == l;
      var last := s[|s| - 1];
      assert last in s;
      assert Rank(last.layer) >= Rank(l);
      assert last.layer == l;
    }
    if Resolve(k, ls).notApplied == Unapplied(l) && Resolve(k, ls).layer.FromLayer? {
      var o := Resolve(k, ls).layer.l;
      assert Live(k, ls, o);
      assert Rank(o) != Rank(l) ==> o != l;
      if Rank(o) >= Rank(l) { assert o == l || Rank(o) > Rank(l); }
    }
  }
}
