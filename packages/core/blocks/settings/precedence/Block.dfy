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

  // What layer l shows.
  function ShownOf(k: Key, ls: Layers, l: Layer): Shown {
    var e := At(ls, l);
    if !e.inTarget then Hidden
    else if !e.bound then Hidden
    else if !Admitted(k, l) then Hidden
    else if e.qualified.Some? then Shown(true, e.qualified.v, e.applied)
    else if e.unqualified.Some? then Shown(false, e.unqualified.v, e.applied)
    else Hidden
  }

  // A value and the layer it came from.
  datatype Won = Won(value: Value, layer: Origin)

  // The value and origin after layer l, which shows s, over those from the layers below it.
  function Over(k: Key, s: Shown, l: Layer, below: Won): Won {
    if s.Shown? && s.applied then Won(if k.composes then Compose(below.value, s.token) else Tok(s.token), FromLayer(l))
    else below
  }

  // Whether the topmost layer that shows anything is unapplied: decided by layer l when it shows something,
  // else by the layers below it.
  function Top(s: Shown, l: Layer, below: Unapplied): Unapplied {
    if !s.Shown? then below else if s.applied then AllApplied else Unapplied(l)
  }

  function Resolve(k: Key, ls: Layers): Resolution {
    var g, h, s, p := ShownOf(k, ls, Global), ShownOf(k, ls, Home), ShownOf(k, ls, Session), ShownOf(k, ls, Project);
    var won := Over(k, p, Project, Over(k, s, Session, Over(k, h, Home, Over(k, g, Global, Won(Default, FromDefault)))));
    Resolution(won.value, won.layer, Top(p, Project, Top(s, Session, Top(h, Home, Top(g, Global, AllApplied)))), Shows(g, h, s, p))
  }

  // The value after layer m's plain value, when it counts below layer l, over the value from the layers below m.
  function PlainOver(k: Key, ls: Layers, m: Layer, below: bool, v: Value): Value {
    var e := At(ls, m);
    if !below then v
    else if !e.inTarget then v
    else if !e.bound then v
    else if !Admitted(k, m) then v
    else if !e.applied then v
    else if e.unqualified.None? then v
    else if k.composes then Compose(v, e.unqualified.v) else Tok(e.unqualified.v)
  }

  // The value from the layers strictly below l: the plain values of Global, Home and Session, lowest first, each
  // counted only when its layer lies below l. Project is the top layer, so it lies below none.
  function Below(k: Key, ls: Layers, l: Layer): Value {
    PlainOver(k, ls, Session, l.Project?,
      PlainOver(k, ls, Home, l.Session? || l.Project?,
        PlainOver(k, ls, Global, !l.Global?, Default)))
  }

  // ---------- proofs ----------

  lemma S1Admission(k: Key) {}

  // The state after layer l: an applied layer that takes part sets the value and the origin.
  ghost function StepL(k: Key, ls: Layers, l: Layer, st: Won): Won {
    if Live(k, ls, l) then Won(Step(k, st.value, TokenOf(At(ls, l))), FromLayer(l)) else st
  }

  // The value and origin after the four layers, lowest first.
  ghost function Steps(k: Key, ls: Layers): Won {
    StepL(k, ls, Project, StepL(k, ls, Session, StepL(k, ls, Home, StepL(k, ls, Global, Won(Default, FromDefault)))))
  }

  lemma ShownOfSpec(k: Key, ls: Layers, l: Layer)
    ensures ShownOf(k, ls, l) == if Visible(k, ls, l)
      then Shown(At(ls, l).qualified.Some?, TokenOf(At(ls, l)), At(ls, l).applied) else Hidden
  {}

  lemma ResolveSteps(k: Key, ls: Layers)
    ensures forall l: Layer :: ShownAt(Resolve(k, ls).shown, l) == ShownOf(k, ls, l)
    ensures Won(Resolve(k, ls).value, Resolve(k, ls).layer) == Steps(k, ls)
  {
    ShownOfSpec(k, ls, Global); ShownOfSpec(k, ls, Home); ShownOfSpec(k, ls, Session); ShownOfSpec(k, ls, Project);
  }

  lemma R2Default(k: Key, ls: Layers)
  { ResolveSteps(k, ls); }

  lemma R1Winner(k: Key, ls: Layers, l: Layer)
  { ResolveSteps(k, ls); }

  lemma R4UntrustedInert(k: Key, ls: Layers, ls2: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    ResolveSteps(k, ls2);
    forall m: Layer ensures Live(k, ls, m) == Live(k, ls2, m) && (Live(k, ls, m) ==> TokenOf(At(ls, m)) == TokenOf(At(ls2, m))) {
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

  lemma FoldedAppend(k: Key, v: Value, a: seq<Token>, b: seq<Token>)
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
    ensures Folded(k, v, if Live(k, ls, l) then [TokenOf(At(ls, l))] else []) == StepL(k, ls, l, Won(v, FromDefault)).value
  {}

  lemma R3Compose(k: Key, ls: Layers)
  {
    ResolveSteps(k, ls);
    var g := if Live(k, ls, Global) then [TokenOf(ls.global)] else [];
    var h := if Live(k, ls, Home) then [TokenOf(ls.home)] else [];
    var se := if Live(k, ls, Session) then [TokenOf(ls.session)] else [];
    var p := if Live(k, ls, Project) then [TokenOf(ls.project)] else [];
    assert LiveTokens(k, ls) == g + h + se + p;
    FoldedAppend(k, Default, g + h + se, p);
    FoldedAppend(k, Default, g + h, se);
    FoldedAppend(k, Default, g, h);
    var v1 := Folded(k, Default, g); FoldedLayer(k, ls, Global, Default);
    var v2 := Folded(k, v1, h); FoldedLayer(k, ls, Home, v1);
    var v3 := Folded(k, v2, se); FoldedLayer(k, ls, Session, v2);
    FoldedLayer(k, ls, Project, v3);
  }

  // One layer's plain value folds like its step below l.
  lemma FoldedPlain(k: Key, ls: Layers, m: Layer, l: Layer, v: Value)
    ensures Folded(k, v, if PlainLive(k, ls, m, l) then [At(ls, m).unqualified.v] else []) == PlainOver(k, ls, m, Rank(m) < Rank(l), v)
  {}

  lemma R8Below(k: Key, ls: Layers, l: Layer)
  {
    var g := if PlainLive(k, ls, Global, l) then [ls.global.unqualified.v] else [];
    var h := if PlainLive(k, ls, Home, l) then [ls.home.unqualified.v] else [];
    var se := if PlainLive(k, ls, Session, l) then [ls.session.unqualified.v] else [];
    assert !PlainLive(k, ls, Project, l);
    assert BelowTokens(k, ls, l) == g + h + se;
    FoldedAppend(k, Default, g + h, se);
    FoldedAppend(k, Default, g, h);
    var v1 := Folded(k, Default, g); FoldedPlain(k, ls, Global, l, Default);
    var v2 := Folded(k, v1, h); FoldedPlain(k, ls, Home, l, v1);
    FoldedPlain(k, ls, Session, l, v2);
  }

  lemma R6Shown(k: Key, ls: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    ShownOfSpec(k, ls, l);
  }

  // The resolution's origin is an applied layer that takes part, or the default.
  lemma OriginLive(k: Key, ls: Layers)
    ensures Steps(k, ls).layer.FromLayer? ==> Live(k, ls, Steps(k, ls).layer.l)
  {}

  lemma R7NotApplied(k: Key, ls: Layers, l: Layer)
  {
    ResolveSteps(k, ls);
    OriginLive(k, ls);
    ShownOfSpec(k, ls, Global); ShownOfSpec(k, ls, Home); ShownOfSpec(k, ls, Session); ShownOfSpec(k, ls, Project);
    if Visible(k, ls, l) && !At(ls, l).applied && forall m: Layer | Rank(m) > Rank(l) :: !Visible(k, ls, m) {
      forall m: Layer | Rank(m) > Rank(l) ensures ShownOf(k, ls, m).Hidden? {}
    }
  }
}
