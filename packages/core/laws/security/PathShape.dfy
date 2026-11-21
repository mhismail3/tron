// Laws of block security/path-shape: whether a path lies within a root (the root itself or below it), and whether
// a delegated subagent artifact path has an allowed shape: a run directory or one of its artifact files under the
// owned runs root, the project runs root or a temporary subagents root.
// Paths enter as their components (the names between `/`) and each name as a token.
// Shells: packages/gateway/src/machine/path-containment.ts (containedWithin) and
// packages/gateway/src/kernel/delegation/delegated-provider.ts (delegatedArtifactPathAllowed: it refuses a relative
// path, a `.` or `..` part and symlinks, resolves the real paths and checks the owned root's ownership, then asks
// the block).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module SecurityPathShapeLaws {
  // Token: the number the shell gives one name of one call. A JavaScript number in the compiled block, which only
  // compares tokens.
  newtype Token = x: int | 0 <= x < 0x1_0000_0000
  // List: a linked list, crossing to the shell as an array.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  // Piece: one non-empty part of a path component split at backslashes: its token, and whether its name begins
  // with pi-subagents-.
  datatype Piece = Piece(name: Token, scoped: bool)
  // Component: one component of an artifact path: its token and its pieces in order.
  datatype Component = Component(name: Token, pieces: List<Piece>)
  // Roots: where artifacts may live: the owned subagents root's runs directory alone, or, when the Gateway owns no
  // subagents root, the temporary root and the project runs directory.
  datatype Roots = Owned(runs: List<Token>) | Shared(temporary: List<Token>, project: List<Token>)

  // Assumption A1: the shell gives equal names equal tokens and distinct names distinct tokens within one call; in
  // an artifact check the four artifact file names (status.json, events.jsonl, recovery-descriptor.json,
  // process-terminal.json) have tokens 0 to 3 and async-subagent-runs token 4.
  // Assumption A2: every path is absolute and resolved, given as its non-empty components in order, none `.` or
  // `..`: for containment the shell resolves the root and the candidate as Node's path.relative did, so a
  // candidate that names `..` is judged where it points; for an artifact the path is the candidate's real path and
  // the roots are the real paths of the owned root (with async-subagent-runs), of the system temporary directory,
  // and of the session cwd with .pi/subagents/async-subagent-runs. A component's pieces are its parts between
  // backslashes, empty ones left out, as the replaced TypeScript split the path below a root at both separators.
  // Assumption A3: the shell asks about an artifact path only after refusing a relative path, a `.` or `..` part
  // and a symlinked owned root or candidate, and after finding the owned root a private directory of the
  // Gateway's user; the block decides the shape only.

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> { if l.Nil? then [] else [l.head] + Elems(l.tail) }

  // Names: the tokens of components, in order.
  ghost function Names(cs: seq<Component>): seq<Token> { seq(|cs|, i requires 0 <= i < |cs| => cs[i].name) }

  // Pieces: the pieces of components, in order.
  ghost function Pieces(cs: seq<Component>): seq<Piece>
    decreases |cs|
  { if |cs| == 0 then [] else Elems(cs[0].pieces) + Pieces(cs[1..]) }

  // Under: the root's components are the path's first components, each compared whole: the path is the root or
  // below it.
  ghost predicate Under(root: seq<Token>, path: seq<Token>) { |root| <= |path| && path[..|root|] == root }

  // IsFile: the name is one of the four artifact file names.
  ghost predicate IsFile(n: Token) { n < 4 }

  // RunShape: one piece (a run directory), or two whose second is an artifact file.
  ghost predicate RunShape(ps: seq<Piece>) { |ps| == 1 || (|ps| == 2 && IsFile(ps[1].name)) }

  // TemporaryShape: a pi-subagents-* directory, async-subagent-runs and a run directory, optionally followed by an
  // artifact file.
  ghost predicate TemporaryShape(ps: seq<Piece>) {
    (|ps| == 3 || (|ps| == 4 && IsFile(ps[3].name))) && ps[0].scoped && ps[1].name == 4
  }

  // InRun: the path is below the root, and the pieces below the root have the run shape.
  ghost predicate InRun(root: seq<Token>, cs: seq<Component>) {
    Under(root, Names(cs)) && RunShape(Pieces(cs[|root|..]))
  }

  // InTemporaryRun: the path is below the root, and the pieces below the root have the temporary shape.
  ghost predicate InTemporaryRun(root: seq<Token>, cs: seq<Component>) {
    Under(root, Names(cs)) && TemporaryShape(Pieces(cs[|root|..]))
  }

  // Whether the path is the root or below it.
  function Contained(root: List<Token>, path: List<Token>): bool

  // Whether the artifact path has an allowed shape under the roots.
  function ArtifactAllowed(roots: Roots, path: List<Component>): bool

  // C1 containment: a path is within a root exactly when it is the root itself or below it: the root's components
  // are its first components, each compared whole. A sibling whose name extends the root's last name (/a/bc under
  // /a/b), an ancestor of the root and an unrelated path are refused; a path that named `..` is judged where it
  // points once resolved, so `..` never escapes.
  lemma C1Containment(root: List<Token>, path: List<Token>)
    ensures Contained(root, path) <==> Under(Elems(root), Elems(path))

  // A1 owned-run: when the Gateway owns a subagents root, an artifact path is allowed exactly when it lies below
  // that root's runs directory as a run directory, or as a run directory and one of the four artifact files; the
  // root itself, deeper paths, other files and the temporary and project roots are refused.
  lemma A1OwnedRun(runs: List<Token>, path: List<Component>)
    ensures ArtifactAllowed(Owned(runs), path) <==> InRun(Elems(runs), Elems(path))

  // A2 shared-run: when the Gateway owns no subagents root, an artifact path is allowed exactly when it lies below
  // the temporary root as a pi-subagents-* directory, async-subagent-runs and a run directory, optionally with one
  // of the four artifact files, or below the project runs directory as a run directory, optionally with one of
  // them. Every other path is refused.
  lemma A2SharedRun(temporary: List<Token>, project: List<Token>, path: List<Component>)
    ensures ArtifactAllowed(Shared(temporary, project), path)
      <==> (InTemporaryRun(Elems(temporary), Elems(path)) || InRun(Elems(project), Elems(path)))
}
