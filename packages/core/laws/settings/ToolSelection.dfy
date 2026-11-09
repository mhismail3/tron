// Laws of block settings/tool-selection: how a layer's tool selection (plain tool names, or +name/-name
// modifiers relative to the layers below) composes with the selection below it, and how a chosen selection is
// stored in a layer (encode) so that composing it back gives exactly the choice. Tool names enter as tokens: the
// shell numbers each distinct name of one call, the empty name being 0.
// Shell: packages/gateway/src/kernel/settings/settings-types.ts (toolSelectionType().compose and .encode, and
// applyToolModifiers: pi's defaultTools merge).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module SettingsToolSelectionLaws {
  // One stored entry: a plain tool name, or a modifier adding (+name) or removing (-name) a tool.
  datatype Entry = Plain(n: int) | Plus(n: int) | Minus(n: int)
  // The selection below a layer: none (no layer below holds a value), or a list of tool names.
  datatype Below = NoBelow | Names(names: seq<int>)
  // What a layer holds after a change: nothing, or a list of entries.
  datatype Held = Nothing | Holds(entries: seq<Entry>)

  // Assumption A1: the shell gives each distinct tool name of one call one token, the empty name token 0 and
  // every other name a positive token, and maps tokens back to the same names; `defaults` are the tokens of
  // pi's default tools (read, bash, edit, write). The shell calls the block only for lists of strings (a
  // stored value of another shape never reaches compose or encode as a selection).

  // IsModifier: the entry adds or removes a tool.
  predicate IsModifier(e: Entry) { e.Plus? || e.Minus? }

  // Plains: the plain names of entries, in order.
  ghost function Plains(es: seq<Entry>): seq<int>
    decreases |es|
  { if |es| == 0 then [] else (if es[0].Plain? then [es[0].n] else []) + Plains(es[1..]) }

  // RemoveFirst: the list without the first occurrence of n (unchanged when n is absent).
  ghost function RemoveFirst(t: seq<int>, n: int): seq<int>
    decreases |t|
  { if |t| == 0 then [] else if t[0] == n then t[1..] else [t[0]] + RemoveFirst(t[1..], n) }

  // Delta: the modifiers that turn `base` into `chosen` when that is possible: an add for each chosen name not
  // in base, in chosen order, then a remove for each base name not chosen, in base order.
  ghost function Delta(chosen: seq<int>, base: seq<int>): seq<Entry> {
    seq(|Adds(chosen, base)|, i requires 0 <= i < |Adds(chosen, base)| => Plus(Adds(chosen, base)[i]))
    + seq(|Adds(base, chosen)|, i requires 0 <= i < |Adds(base, chosen)| => Minus(Adds(base, chosen)[i]))
  }

  // Adds: the names of a that are not in b, in a's order (repeats kept).
  ghost function Adds(a: seq<int>, b: seq<int>): seq<int>
    decreases |a|
  { if |a| == 0 then [] else (if a[0] in b then [] else [a[0]]) + Adds(a[1..], b) }

  // Nodup: no name appears twice.
  ghost predicate Nodup(t: seq<int>) { forall i, j | 0 <= i < j < |t| :: t[i] != t[j] }

  // The tools after applying the modifiers of entries, in order, to tools (plain entries are skipped).
  function Mods(tools: seq<int>, entries: seq<Entry>): seq<int>
    decreases |entries|

  // A layer's entries composed with the selection below it.
  function Compose(below: Below, entries: seq<Entry>, defaults: seq<int>): seq<int>

  // What a layer holds after the user chooses `chosen`, given the selection below it and what it holds now.
  function Encode(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>): Held

  // M1 modifier-steps: applying no entry changes nothing; a plain entry changes nothing; +name appends the
  // tool when it is not listed and its name is not empty; -name removes its first occurrence (if any).
  lemma M1ModifierSteps(t: seq<int>, n: int)
    ensures Mods(t, []) == t && Mods(t, [Plain(n)]) == t
    ensures Mods(t, [Plus(n)]) == if n != 0 && n !in t then t + [n] else t
    ensures Mods(t, [Minus(n)]) == RemoveFirst(t, n)

  // M2 modifier-sequence: entries apply one after another, in order.
  lemma M2ModifierSequence(t: seq<int>, a: seq<Entry>, b: seq<Entry>)
    ensures Mods(t, a + b) == Mods(Mods(t, a), b)

  // C1 modifiers-over-below: a layer holding only modifiers (at least one), over a selection below it, applies
  // them to that selection.
  lemma C1ModifiersOverBelow(below: seq<int>, es: seq<Entry>, defaults: seq<int>)
    requires |es| > 0 && forall i | 0 <= i < |es| :: IsModifier(es[i])
    ensures Compose(Names(below), es, defaults) == Mods(below, es)

  // C2 plain-list: a layer holding at least one plain name replaces the selection below: its plain names in
  // order, then its modifiers applied to them.
  lemma C2PlainList(below: Below, es: seq<Entry>, defaults: seq<int>)
    requires exists i | 0 <= i < |es| :: es[i].Plain?
    ensures Compose(below, es, defaults) == Mods(Plains(es), es)

  // C3 modifiers-over-defaults: a layer holding only modifiers (at least one) with nothing below applies them
  // to pi's default tools.
  lemma C3ModifiersOverDefaults(es: seq<Entry>, defaults: seq<int>)
    requires |es| > 0 && forall i | 0 <= i < |es| :: IsModifier(es[i])
    ensures Compose(NoBelow, es, defaults) == Mods(defaults, es)

  // C4 empty-is-no-tools: a layer holding an empty list selects no tools, whatever lies below.
  lemma C4EmptyIsNoTools(below: Below, defaults: seq<int>)
    ensures Compose(below, [], defaults) == []

  // B1 no-duplicates: when the list the entries start from has no tool twice (the plain names, the selection
  // below, or the defaults), the composed selection has no tool twice.
  lemma B1NoDuplicates(below: Below, es: seq<Entry>, defaults: seq<int>)
    requires Nodup(Plains(es)) && (below.Names? ==> Nodup(below.names)) && Nodup(defaults)
    ensures Nodup(Compose(below, es, defaults))

  // E1 modifiers-kept: a chosen list that itself holds a modifier is stored exactly as chosen.
  lemma E1ModifiersKept(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
    requires exists i | 0 <= i < |chosen| :: IsModifier(chosen[i])
    ensures Encode(chosen, below, current, defaults) == Holds(chosen)

  // E2 plain-layer-stays-plain: a layer that holds a plain name now stores the chosen list as it is.
  lemma E2PlainStaysPlain(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
    requires exists i | 0 <= i < |current| :: current[i].Plain?
    ensures Encode(chosen, below, current, defaults) == Holds(chosen)

  // E3 round-trip: whatever a layer stores for a choice of plain names, composing it with the selection below
  // gives exactly the chosen names in the chosen order (storing nothing leaves the selection below, or the
  // defaults when nothing lies below).
  lemma E3RoundTrip(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    ensures var r := Encode(chosen, below, current, defaults);
      Plains(chosen) == match r
        case Nothing => (if below.Names? then below.names else defaults)
        case Holds(es) => Compose(below, es, defaults)

  // E4 relative-when-reproducible: a choice of plain names over a layer holding only modifiers (or nothing) is
  // stored relative to the selection below (or the defaults), as Delta's adds then removes, when those
  // reproduce the choice in its order; storing nothing when no modifier is needed.
  lemma E4RelativeWhenReproducible(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    requires forall i | 0 <= i < |current| :: IsModifier(current[i])
    ensures var base := if below.Names? then below.names else defaults;
      var d := Delta(Plains(chosen), base);
      Mods(base, d) == Plains(chosen) ==> Encode(chosen, below, current, defaults) == (if |d| == 0 then Nothing else Holds(d))

  // E5 plain-when-order-differs: when Delta's modifiers cannot reproduce the chosen order, the choice is stored
  // as the plain list (the user's order outranks following later changes below).
  lemma E5PlainWhenOrderDiffers(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<int>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    ensures var base := if below.Names? then below.names else defaults;
      Mods(base, Delta(Plains(chosen), base)) != Plains(chosen) ==> Encode(chosen, below, current, defaults) == Holds(chosen)
}
