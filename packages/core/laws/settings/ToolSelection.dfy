// Laws of block settings/tool-selection: how a layer's tool selection (plain tool names, or +name/-name
// modifiers relative to the layers below) composes with the selection below it, and how a chosen selection is
// stored in a layer (encode) so that composing it back gives exactly the choice. Tool names enter as tokens: the
// shell numbers each distinct name of one call, the empty name being 0.
// Compose and Encode are defined here over sequences, and laws M1 to E5 say what they do. The shell runs
// ComposeList and EncodeList, which work on linked lists; laws L1 and L2 say they compute exactly Compose and Encode.
// Shell: packages/gateway/src/kernel/settings/settings-types.ts (toolSelectionType().compose and .encode: pi's
// defaultTools merge).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module SettingsToolSelectionLaws {
  // Token: the number the shell gives one tool name for one call; 0 is the empty name. A JavaScript number in
  // the compiled block, which only compares tokens.
  newtype Token = x: int | 0 <= x < 0x1_0000_0000
  // One stored entry: a plain tool name, or a modifier adding (+name) or removing (-name) a tool.
  datatype Entry = Plain(n: Token) | Plus(n: Token) | Minus(n: Token)
  // The selection below a layer: none (no layer below holds a value), or a list of tool names.
  datatype Below = NoBelow | Names(names: seq<Token>)
  // What a layer holds after a change: nothing, or a list of entries.
  datatype Held = Nothing | Holds(entries: seq<Entry>)

  // List: a linked list, the form in which the compiled block reads and builds lists.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  // Below and Held with linked lists.
  datatype BelowList = NoBelowList | NamesList(names: List<Token>)
  datatype HeldList = NothingList | HoldsList(entries: List<Entry>)

  // Assumption A1: the shell gives each distinct tool name of one call one token, the empty name token 0 and
  // every other name a positive token, and maps tokens back to the same names; `defaults` are the tokens of
  // pi's default tools (read, bash, edit, write). Entries reach the block only from lists of strings (the shell
  // refuses any other list before calling it); the selection below is an earlier Compose result or a declared
  // default, so its names are strings too. Of what a layer holds now, Encode asks only whether an entry is a
  // plain name, and only for a choice of plain names: the shell may pass those entries up to the first plain
  // name and none for a choice that holds a modifier.

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> {
    match l
    case Nil => []
    case Cons(head, tail) => [head] + Elems(tail)
  }

  // BelowOf, HeldOf: the selection below and the held entries that the linked-list forms stand for.
  ghost function BelowOf(b: BelowList): Below { if b.NamesList? then Names(Elems(b.names)) else NoBelow }
  ghost function HeldOf(h: HeldList): Held { if h.HoldsList? then Holds(Elems(h.entries)) else Nothing }

  // IsModifier: the entry adds or removes a tool.
  predicate IsModifier(e: Entry) { e.Plus? || e.Minus? }

  // AllModifiers: every entry adds or removes a tool (true of no entries).
  ghost predicate AllModifiers(es: seq<Entry>) { forall i | 0 <= i < |es| :: IsModifier(es[i]) }

  // Plains: the plain names of entries, in order.
  ghost function Plains(es: seq<Entry>): seq<Token>
    decreases |es|
  { if |es| == 0 then [] else (if es[0].Plain? then [es[0].n] else []) + Plains(es[1..]) }

  // RemoveFirst: the list without the first occurrence of n (unchanged when n is absent).
  ghost function RemoveFirst(t: seq<Token>, n: Token): seq<Token>
    decreases |t|
  { if |t| == 0 then [] else if t[0] == n then t[1..] else [t[0]] + RemoveFirst(t[1..], n) }

  // Delta: the modifiers that turn `base` into `chosen` when that is possible: an add for each chosen name not
  // in base, in chosen order, then a remove for each base name not chosen, in base order.
  ghost function Delta(chosen: seq<Token>, base: seq<Token>): seq<Entry> {
    seq(|Adds(chosen, base)|, i requires 0 <= i < |Adds(chosen, base)| => Plus(Adds(chosen, base)[i]))
    + seq(|Adds(base, chosen)|, i requires 0 <= i < |Adds(base, chosen)| => Minus(Adds(base, chosen)[i]))
  }

  // Adds: the names of a that are not in b, in a's order (repeats kept).
  ghost function Adds(a: seq<Token>, b: seq<Token>): seq<Token>
    decreases |a|
  { if |a| == 0 then [] else (if a[0] in b then [] else [a[0]]) + Adds(a[1..], b) }

  // Nodup: no name appears twice.
  ghost predicate Nodup(t: seq<Token>) { forall i, j | 0 <= i < j < |t| :: t[i] != t[j] }

  // Mods: the tools after applying the modifiers of entries, in order, to tools: a plain entry changes nothing,
  // +name appends the tool when it is not listed and its name is not empty, -name removes its first occurrence.
  ghost function Mods(tools: seq<Token>, entries: seq<Entry>): seq<Token>
    decreases |entries|
  {
    if |entries| == 0 then tools
    else
      var next := match entries[0]
        case Plain(_) => tools
        case Plus(n) => if n != 0 && n !in tools then tools + [n] else tools
        case Minus(n) => RemoveFirst(tools, n);
      Mods(next, entries[1..])
  }

  // Compose: a layer's entries composed with the selection below it: modifiers only (at least one) apply to
  // the selection below, or to the defaults when nothing lies below; otherwise the layer's plain names replace
  // what lies below, and its modifiers apply to them.
  ghost function Compose(below: Below, entries: seq<Entry>, defaults: seq<Token>): seq<Token> {
    if below.Names? && |entries| > 0 && AllModifiers(entries) then Mods(below.names, entries)
    else
      var plain := Plains(entries);
      Mods(if |plain| > 0 || |entries| == 0 then plain else defaults, entries)
  }

  // Encode: what a layer holds after the user chooses `chosen`, given the selection below it and what it holds
  // now: the choice as it is when it holds a modifier or the layer holds a plain name; otherwise the modifiers
  // that turn the selection below (or the defaults) into the choice when they reproduce it, nothing when none
  // is needed, and the choice as it is when they cannot reproduce its order.
  ghost function Encode(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>): Held {
    if exists i | 0 <= i < |chosen| :: IsModifier(chosen[i]) then Holds(chosen)
    else if !AllModifiers(current) then Holds(chosen)
    else
      var base := if below.Names? then below.names else defaults;
      var delta := Delta(Plains(chosen), base);
      if Mods(base, delta) != Plains(chosen) then Holds(chosen)
      else if |delta| > 0 then Holds(delta) else Nothing
  }

  // ComposeList: Compose on linked lists (what the shell calls).
  function ComposeList(below: BelowList, entries: List<Entry>, defaults: List<Token>): List<Token>

  // EncodeList: Encode on linked lists (what the shell calls).
  function EncodeList(chosen: List<Entry>, below: BelowList, current: List<Entry>, defaults: List<Token>): HeldList

  // L1 compose-computed: for every selection below, entries and defaults, ComposeList gives exactly the tools
  // Compose gives for the same lists, in the same order.
  lemma L1ComposeComputed(below: BelowList, entries: List<Entry>, defaults: List<Token>)
    ensures Elems(ComposeList(below, entries, defaults)) == Compose(BelowOf(below), Elems(entries), Elems(defaults))

  // L2 encode-computed: for every choice, selection below, held entries and defaults, EncodeList gives exactly
  // what Encode gives for the same lists: nothing, or the same entries in the same order.
  lemma L2EncodeComputed(chosen: List<Entry>, below: BelowList, current: List<Entry>, defaults: List<Token>)
    ensures HeldOf(EncodeList(chosen, below, current, defaults))
      == Encode(Elems(chosen), BelowOf(below), Elems(current), Elems(defaults))

  // M1 modifier-steps: applying no entry changes nothing; a plain entry changes nothing; +name appends the
  // tool when it is not listed and its name is not empty; -name removes its first occurrence (if any).
  lemma M1ModifierSteps(t: seq<Token>, n: Token)
    ensures Mods(t, []) == t && Mods(t, [Plain(n)]) == t
    ensures Mods(t, [Plus(n)]) == if n != 0 && n !in t then t + [n] else t
    ensures Mods(t, [Minus(n)]) == RemoveFirst(t, n)

  // M2 modifier-sequence: entries apply one after another, in order.
  lemma M2ModifierSequence(t: seq<Token>, a: seq<Entry>, b: seq<Entry>)
    ensures Mods(t, a + b) == Mods(Mods(t, a), b)

  // C1 modifiers-over-below: a layer holding only modifiers (at least one), over a selection below it, applies
  // them to that selection.
  lemma C1ModifiersOverBelow(below: seq<Token>, es: seq<Entry>, defaults: seq<Token>)
    requires |es| > 0 && forall i | 0 <= i < |es| :: IsModifier(es[i])
    ensures Compose(Names(below), es, defaults) == Mods(below, es)

  // C2 plain-list: a layer holding at least one plain name replaces the selection below: its plain names in
  // order, then its modifiers applied to them.
  lemma C2PlainList(below: Below, es: seq<Entry>, defaults: seq<Token>)
    requires exists i | 0 <= i < |es| :: es[i].Plain?
    ensures Compose(below, es, defaults) == Mods(Plains(es), es)

  // C3 modifiers-over-defaults: a layer holding only modifiers (at least one) with nothing below applies them
  // to pi's default tools.
  lemma C3ModifiersOverDefaults(es: seq<Entry>, defaults: seq<Token>)
    requires |es| > 0 && forall i | 0 <= i < |es| :: IsModifier(es[i])
    ensures Compose(NoBelow, es, defaults) == Mods(defaults, es)

  // C4 empty-is-no-tools: a layer holding an empty list selects no tools, whatever lies below.
  lemma C4EmptyIsNoTools(below: Below, defaults: seq<Token>)
    ensures Compose(below, [], defaults) == []

  // B1 no-duplicates: when the layer's plain names, the selection below it and the defaults each have no tool
  // twice, the composed selection has no tool twice.
  lemma B1NoDuplicates(below: Below, es: seq<Entry>, defaults: seq<Token>)
    requires Nodup(Plains(es)) && (below.Names? ==> Nodup(below.names)) && Nodup(defaults)
    ensures Nodup(Compose(below, es, defaults))

  // E1 modifiers-kept: a chosen list that itself holds a modifier is stored exactly as chosen.
  lemma E1ModifiersKept(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    requires exists i | 0 <= i < |chosen| :: IsModifier(chosen[i])
    ensures Encode(chosen, below, current, defaults) == Holds(chosen)

  // E2 plain-layer-stays-plain: a layer that holds a plain name now stores the chosen list as it is.
  lemma E2PlainStaysPlain(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    requires exists i | 0 <= i < |current| :: current[i].Plain?
    ensures Encode(chosen, below, current, defaults) == Holds(chosen)

  // E3 round-trip: whatever a layer stores for a choice of plain names, composing it with the selection below
  // gives exactly the chosen names in the chosen order (storing nothing leaves the selection below, or the
  // defaults when nothing lies below).
  lemma E3RoundTrip(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    ensures var r := Encode(chosen, below, current, defaults);
      Plains(chosen) == match r
        case Nothing => (if below.Names? then below.names else defaults)
        case Holds(es) => Compose(below, es, defaults)

  // E4 relative-when-reproducible: a choice of plain names over a layer holding only modifiers (or nothing) is
  // stored relative to the selection below (or the defaults), as Delta's adds then removes, when those
  // reproduce the choice in its order; storing nothing when no modifier is needed.
  lemma E4RelativeWhenReproducible(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    requires forall i | 0 <= i < |current| :: IsModifier(current[i])
    ensures var base := if below.Names? then below.names else defaults;
      var d := Delta(Plains(chosen), base);
      Mods(base, d) == Plains(chosen) ==> Encode(chosen, below, current, defaults) == (if |d| == 0 then Nothing else Holds(d))

  // E5 plain-when-order-differs: when Delta's modifiers cannot reproduce the chosen order, the choice is stored
  // as the plain list (the user's order outranks following later changes below).
  lemma E5PlainWhenOrderDiffers(chosen: seq<Entry>, below: Below, current: seq<Entry>, defaults: seq<Token>)
    requires forall i | 0 <= i < |chosen| :: chosen[i].Plain?
    ensures var base := if below.Names? then below.names else defaults;
      Mods(base, Delta(Plains(chosen), base)) != Plains(chosen) ==> Encode(chosen, below, current, defaults) == Holds(chosen)
}
