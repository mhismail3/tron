// Block security/path-shape: definitions and proofs of laws/security/PathShape.dfy.
include "../../../laws/security/PathShape.dfy"

module SecurityPathShape refines SecurityPathShapeLaws {
  // ---------- definitions (compiled to JS) ----------
  // Every walk is tail-recursive, so it compiles to a loop and a path of any length is safe.

  // Index: which piece of a path a walk asks for, counted from 0.
  newtype Index = x: int | 0 <= x < 8
  // Pick: the piece a walk found, or none.
  datatype Pick = NoPick | Picked(piece: Piece)
  // Rest: the components of a path below a root, or Outside when the path is neither the root nor below it.
  datatype Rest = Outside | Inside(rest: List<Component>)

  function Contained(root: List<Token>, path: List<Token>): bool {
    if root.Nil? then true
    else if path.Nil? || root.head != path.head then false
    else Contained(root.tail, path.tail)
  }

  // The components of the path below the root.
  function Below(root: List<Token>, path: List<Component>): Rest {
    if root.Nil? then Inside(path)
    else if path.Nil? || root.head != path.head.name then Outside
    else Below(root.tail, path.tail)
  }

  // The k-th piece of the pieces ps followed by the pieces of the components cs.
  function Nth(ps: List<Piece>, cs: List<Component>, k: Index): Pick
    decreases cs, ps
  {
    if ps.Cons? then (if k == 0 then Picked(ps.head) else Nth(ps.tail, cs, k - 1))
    else if cs.Nil? then NoPick
    else Nth(cs.head.pieces, cs.tail, k)
  }

  // The pieces of the components are a run directory, optionally followed by an artifact file.
  predicate Run(cs: List<Component>) {
    var second := Nth(Nil, cs, 1);
    Nth(Nil, cs, 0).Picked? && (second.NoPick? || (second.piece.name < 4 && Nth(Nil, cs, 2).NoPick?))
  }

  // The pieces of the components are a pi-subagents-* directory, async-subagent-runs and a run directory,
  // optionally followed by an artifact file.
  predicate TemporaryRun(cs: List<Component>) {
    var first := Nth(Nil, cs, 0);
    var second := Nth(Nil, cs, 1);
    var fourth := Nth(Nil, cs, 3);
    first.Picked? && first.piece.scoped && second.Picked? && second.piece.name == 4 && Nth(Nil, cs, 2).Picked?
    && (fourth.NoPick? || (fourth.piece.name < 4 && Nth(Nil, cs, 4).NoPick?))
  }

  function ArtifactAllowed(roots: Roots, path: List<Component>): bool {
    if roots.Owned? then
      var runs := Below(roots.runs, path);
      runs.Inside? && Run(runs.rest)
    else
      var temporary := Below(roots.temporary, path);
      var project := Below(roots.project, path);
      (temporary.Inside? && TemporaryRun(temporary.rest)) || (project.Inside? && Run(project.rest))
  }

  // ---------- proofs ----------

  // The items of a non-empty list: its head, then the items of its tail.
  lemma ElemsCons<T>(l: List<T>)
    requires l.Cons?
    ensures |Elems(l)| == 1 + |Elems(l.tail)| && Elems(l)[0] == l.head && Elems(l)[1..] == Elems(l.tail)
  {}

  // Contained compares the root's components with the path's first components, each whole.
  lemma ContainedSpec(root: List<Token>, path: List<Token>)
    ensures Contained(root, path) <==> Under(Elems(root), Elems(path))
    decreases root
  {
    if root.Cons? {
      ElemsCons(root);
      if path.Cons? {
        ElemsCons(path);
        ContainedSpec(root.tail, path.tail);
        var r, p := Elems(root), Elems(path);
        if Under(r, p) { assert p[0] == r[0]; assert p[1..][..|r| - 1] == r[1..]; }
        if root.head == path.head && Under(r[1..], p[1..]) { assert p[..|r|] == [p[0]] + p[1..][..|r| - 1]; }
      }
    }
  }

  lemma C1Containment(root: List<Token>, path: List<Token>)
  { ContainedSpec(root, path); }

  // The names of components: the first component's name, then the names of the rest.
  lemma NamesCons(cs: seq<Component>)
    requires |cs| > 0
    ensures Names(cs) == [cs[0].name] + Names(cs[1..])
  {}

  // Below finds the components of the path below the root exactly when the path is the root or below it.
  lemma BelowSpec(root: List<Token>, path: List<Component>)
    ensures Below(root, path).Inside? <==> Under(Elems(root), Names(Elems(path)))
    ensures Below(root, path).Inside? ==> Elems(Below(root, path).rest) == Elems(path)[|Elems(root)|..]
    decreases root
  {
    if root.Cons? {
      ElemsCons(root);
      if path.Cons? {
        ElemsCons(path);
        NamesCons(Elems(path));
        BelowSpec(root.tail, path.tail);
        var r, n := Elems(root), Names(Elems(path));
        if Under(r, n) { assert n[0] == r[0]; assert n[1..][..|r| - 1] == r[1..]; }
        if root.head == path.head.name && Under(r[1..], n[1..]) { assert n[..|r|] == [n[0]] + n[1..][..|r| - 1]; }
        if |r| <= |Elems(path)| { assert Elems(path)[|r|..] == Elems(path.tail)[|r| - 1..]; }
      }
    }
  }

  // The pieces of components: the first component's pieces, then the pieces of the rest.
  lemma PiecesCons(cs: List<Component>)
    requires cs.Cons?
    ensures Pieces(Elems(cs)) == Elems(cs.head.pieces) + Pieces(Elems(cs.tail))
  { ElemsCons(cs); }

  // Nth finds the k-th piece of the pieces followed by the pieces of the components, when there is one.
  lemma NthSpec(ps: List<Piece>, cs: List<Component>, k: Index)
    ensures var all := Elems(ps) + Pieces(Elems(cs));
      Nth(ps, cs, k) == if (k as int) < |all| then Picked(all[k]) else NoPick
    decreases cs, ps
  {
    if ps.Cons? {
      ElemsCons(ps);
      if k != 0 { NthSpec(ps.tail, cs, k - 1); }
    } else if cs.Cons? {
      PiecesCons(cs);
      NthSpec(cs.head.pieces, cs.tail, k);
    }
  }

  // Run and TemporaryRun decide the run shapes of the pieces of the components.
  lemma ShapeSpec(cs: List<Component>)
    ensures Run(cs) <==> RunShape(Pieces(Elems(cs)))
    ensures TemporaryRun(cs) <==> TemporaryShape(Pieces(Elems(cs)))
  {
    var all := Pieces(Elems(cs));
    assert Elems<Piece>(Nil) + all == all;
    NthSpec(Nil, cs, 0); NthSpec(Nil, cs, 1); NthSpec(Nil, cs, 2); NthSpec(Nil, cs, 3); NthSpec(Nil, cs, 4);
  }

  lemma A1OwnedRun(runs: List<Token>, path: List<Component>)
  {
    BelowSpec(runs, path);
    if Below(runs, path).Inside? { ShapeSpec(Below(runs, path).rest); }
  }

  lemma A2SharedRun(temporary: List<Token>, project: List<Token>, path: List<Component>)
  {
    BelowSpec(temporary, path);
    BelowSpec(project, path);
    if Below(temporary, path).Inside? { ShapeSpec(Below(temporary, path).rest); }
    if Below(project, path).Inside? { ShapeSpec(Below(project, path).rest); }
  }
}
