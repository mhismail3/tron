// Laws of block settings/precedence: which layer's value a setting resolves to, which layer's value is
// shown as not applied (an untrusted project), and what a composing setting's layers below a given layer
// add up to. Settings values never enter the block: the shell gives each distinct value of one call a token
// (an integer), and a resolved value is a term over tokens (the default, one token, or a composition).
// Shell: packages/gateway/src/kernel/settings/settings-resolver.ts (the value, layer and not-applied fold of
// resolveInstance, and composedBelow) and scope-resolution.ts (scopeAdmitted).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module SettingsPrecedenceLaws {
  // The four stored layers, lowest first; the built-in default lies below all of them.
  datatype Layer = Global | Home | Session | Project
  // Token: the name the shell gives one value of one call. The block passes tokens on and never compares or
  // computes with them. A JavaScript number in the compiled block.
  newtype Token = x: int | 0 <= x < 0x1_0000_0000
  datatype Opt = None | Some(v: Token)
  // One layer's facts for one setting: whether the target (Global, a project, a chat, Home) has the layer,
  // whether the setting is stored in that layer at all, the layer's per-model and plain values (tokens) if
  // set, and whether the layer is applied (a project's settings apply only while the project is trusted).
  datatype Entry = Entry(inTarget: bool, bound: bool, qualified: Opt, unqualified: Opt, applied: bool)
  datatype Layers = Layers(global: Entry, home: Entry, session: Entry, project: Entry)
  // What the setting's declaration says: whether a project may set it, whether a chat or Home may override
  // it, and whether a layer's value composes with the value below it (a tool selection's +name/-name).
  datatype Key = Key(projectSettable: bool, sessionOverridable: bool, composes: bool)
  datatype Value = Default | Tok(t: Token) | Compose(below: Value, t: Token)
  datatype Origin = FromDefault | FromLayer(l: Layer)
  datatype Unapplied = AllApplied | Unapplied(l: Layer)
  // What one layer shows for the setting: nothing, or its value (a token), whether that is the per-model value,
  // and whether the layer is applied.
  datatype Shown = Hidden | Shown(qualified: bool, token: Token, applied: bool)
  datatype Shows = Shows(global: Shown, home: Shown, session: Shown, project: Shown)
  datatype Resolution = Resolution(value: Value, layer: Origin, notApplied: Unapplied, shown: Shows)

  // Assumption A1: in one call the shell gives each value it reads its own token (a layer's per-model value and
  // its plain value are two tokens), the default value token 0, and turns a Compose term into a value by calling
  // the setting type's own compose. The block decides which values take part and in what order; it never sees,
  // compares or combines values, so whether two tokens stand for equal values changes no decision.
  // Assumption A2: an entry's qualified token is the layer's value for the chat's model (a per-model value),
  // its plain token the layer's ordinary value, both read by the shell from the layer's store; `applied` is
  // false only for the Project layer of an untrusted project.

  // Rank: the precedence order, Global 1 < Home 2 < Session 3 < Project 4 (Project above Session, decided by
  // Mohsin, H1); the default is below every layer.
  ghost function Rank(l: Layer): int {
    match l
    case Global => 1
    case Home => 2
    case Session => 3
    case Project => 4
  }

  // The entry the layers hold for layer l.
  function At(ls: Layers, l: Layer): Entry {
    match l
    case Global => ls.global
    case Home => ls.home
    case Session => ls.session
    case Project => ls.project
  }

  // Whether the setting's declaration admits a value from layer l.
  predicate Admitted(k: Key, l: Layer)

  // Visible: layer l takes part: the target has it, the setting is stored there, the declaration admits it,
  // and the layer holds a per-model or plain value.
  ghost predicate Visible(k: Key, ls: Layers, l: Layer) {
    var e := At(ls, l);
    e.inTarget && e.bound && Admitted(k, l) && (e.qualified.Some? || e.unqualified.Some?)
  }

  // TokenOf: a layer's shown value: its per-model value when it has one, else its plain value.
  ghost function TokenOf(e: Entry): Token
    requires e.qualified.Some? || e.unqualified.Some?
  { if e.qualified.Some? then e.qualified.v else e.unqualified.v }

  // Live: layer l takes part and is applied.
  ghost predicate Live(k: Key, ls: Layers, l: Layer) { Visible(k, ls, l) && At(ls, l).applied }

  // Step: the value after one more applied layer: the layer's value composed with the value below it for a
  // composing setting, else the layer's value alone.
  ghost function Step(k: Key, below: Value, t: Token): Value { if k.composes then Compose(below, t) else Tok(t) }

  // Folded: the value after applied layers with tokens ts, lowest first, starting from v.
  ghost function Folded(k: Key, v: Value, ts: seq<Token>): Value
    decreases |ts|
  { if |ts| == 0 then v else Folded(k, Step(k, v, ts[0]), ts[1..]) }

  // The tokens of the applied layers that take part, lowest first.
  ghost function LiveTokens(k: Key, ls: Layers): seq<Token> {
    (if Live(k, ls, Global) then [TokenOf(ls.global)] else [])
    + (if Live(k, ls, Home) then [TokenOf(ls.home)] else [])
    + (if Live(k, ls, Session) then [TokenOf(ls.session)] else [])
    + (if Live(k, ls, Project) then [TokenOf(ls.project)] else [])
  }

  // What the resolution shows for layer l.
  ghost function ShownAt(s: Shows, l: Layer): Shown {
    match l
    case Global => s.global
    case Home => s.home
    case Session => s.session
    case Project => s.project
  }

  // The setting's resolution in the target.
  function Resolve(k: Key, ls: Layers): Resolution

  // The value of a composing setting from the layers strictly below layer l: what that layer's entries are
  // relative to.
  function Below(k: Key, ls: Layers, l: Layer): Value

  // S1 admission: a value from Global is always admitted, from a chat or Home only when the setting may be
  // overridden per chat, and from a project only when a project may set it.
  lemma S1Admission(k: Key)
    ensures Admitted(k, Global)
    ensures Admitted(k, Home) == k.sessionOverridable && Admitted(k, Session) == k.sessionOverridable
    ensures Admitted(k, Project) == k.projectSettable

  // R1 winner: the setting resolves to the highest applied layer that takes part, so a Project value beats
  // Session, Session beats Home, Home beats Global; and an ordinary (non-composing) setting's value is that
  // layer's shown value.
  lemma R1Winner(k: Key, ls: Layers, l: Layer)
    requires Live(k, ls, l) && forall m: Layer | Rank(m) > Rank(l) :: !Live(k, ls, m)
    ensures Resolve(k, ls).layer == FromLayer(l)
    ensures !k.composes ==> Resolve(k, ls).value == Tok(TokenOf(At(ls, l)))

  // R2 default: when no applied layer takes part, the setting resolves to its default, from the default layer.
  lemma R2Default(k: Key, ls: Layers)
    requires forall m: Layer :: !Live(k, ls, m)
    ensures Resolve(k, ls).value == Default && Resolve(k, ls).layer == FromDefault

  // R3 compose: a composing setting's value is the default composed, lowest layer first, with every applied
  // layer that takes part (each layer's shown value).
  lemma R3Compose(k: Key, ls: Layers)
    requires k.composes
    ensures Resolve(k, ls).value == Folded(k, Default, LiveTokens(k, ls))

  // R4 untrusted-inert: a layer that is not applied never changes the resolved value or layer: two targets
  // that differ only in the values held by an unapplied layer resolve the same.
  lemma R4UntrustedInert(k: Key, ls: Layers, ls2: Layers, l: Layer)
    requires !At(ls, l).applied
    requires At(ls2, l) == At(ls, l).(qualified := At(ls2, l).qualified, unqualified := At(ls2, l).unqualified)
    requires forall m: Layer | m != l :: At(ls2, m) == At(ls, m)
    ensures Resolve(k, ls2).value == Resolve(k, ls).value && Resolve(k, ls2).layer == Resolve(k, ls).layer

  // R5 higher-scope-wins: for an ordinary setting, once a higher layer is applied and takes part, nothing in
  // any lower layer (a per-model value included: scope outranks specificity) changes the value or the layer.
  lemma R5HigherScopeWins(k: Key, ls: Layers, ls2: Layers, l: Layer)
    requires !k.composes && Live(k, ls, l)
    requires forall m: Layer | Rank(m) >= Rank(l) :: At(ls2, m) == At(ls, m)
    ensures Resolve(k, ls2).value == Resolve(k, ls).value && Resolve(k, ls2).layer == Resolve(k, ls).layer

  // R6 shown: a layer is shown exactly when it takes part, with its per-model value when it has one (else its
  // plain value), whether that value is the per-model one, and whether the layer applies.
  lemma R6Shown(k: Key, ls: Layers, l: Layer)
    ensures var s := ShownAt(Resolve(k, ls).shown, l); var e := At(ls, l);
      (s.Shown? <==> Visible(k, ls, l))
      && (s.Shown? ==> s.token == TokenOf(e) && s.qualified == e.qualified.Some? && s.applied == e.applied)

  // R7 not-applied: a layer is reported as not applied exactly when it is the highest layer that takes part
  // and it is not applied (an untrusted project's value would win); the resolution then comes from below it.
  lemma R7NotApplied(k: Key, ls: Layers, l: Layer)
    ensures Resolve(k, ls).notApplied == Unapplied(l)
      <==> (Visible(k, ls, l) && !At(ls, l).applied && forall m: Layer | Rank(m) > Rank(l) :: !Visible(k, ls, m))
    ensures Resolve(k, ls).notApplied == Unapplied(l) ==>
      Resolve(k, ls).layer.FromDefault? || Rank(Resolve(k, ls).layer.l) < Rank(l)

  // R8 below: the value below layer l composes, lowest first, the plain values (never per-model ones) of the
  // applied layers strictly below l that take part.
  lemma R8Below(k: Key, ls: Layers, l: Layer)
    ensures Below(k, ls, l) == Folded(k, Default, BelowTokens(k, ls, l))

  // The plain-value tokens of the applied, admitted layers strictly below l that are in the target, bound and
  // hold a plain value, lowest first.
  ghost function BelowTokens(k: Key, ls: Layers, l: Layer): seq<Token> {
    (if PlainLive(k, ls, Global, l) then [ls.global.unqualified.v] else [])
    + (if PlainLive(k, ls, Home, l) then [ls.home.unqualified.v] else [])
    + (if PlainLive(k, ls, Session, l) then [ls.session.unqualified.v] else [])
    + (if PlainLive(k, ls, Project, l) then [ls.project.unqualified.v] else [])
  }

  // PlainLive: layer m is strictly below l, in the target, bound, admitted, applied and holds a plain value.
  ghost predicate PlainLive(k: Key, ls: Layers, m: Layer, l: Layer) {
    var e := At(ls, m);
    Rank(m) < Rank(l) && e.inTarget && e.bound && Admitted(k, m) && e.applied && e.unqualified.Some?
  }
}
