# Generated façades and wire codecs

`scripts/tron proof facade` and `scripts/tron proof wire` ([proof toolchain](../README.md)): what they generate
from Dafny sources, and what they refuse.

## Façade

`dafny2wire/facade.mjs` (`proof facade <block> [--check] [--root <dir>]`) writes a block's compiled core and
`facade.ts`, a typed TypeScript wrapper generated from the datatypes and compiled signatures of the block's laws.
The façade exposes every compiled function and predicate of the laws (ghost and commented-out declarations are
not compiled, so not exposed) and checks each stated precondition before calling, because compiled code does not
check `requires`. Refused before anything is written: Dafny 3 `function method` syntax, preconditions other than
a call of a compiled predicate on parameters, generic functions, and any Dafny type the block's kind does not
carry (an unused generic datatype is ignored). `--check` regenerates into a temporary directory and exits 1 if
the checked-in files differ.

Every block names the shell that runs it (`block.json` `shell`, a directory relative to the repository); its core
and façade are written there as `core.mjs` and `facade.ts`. `core.mjs` imports nothing: it is the output of `dafny translate js` without the
Dafny runtime, byte for byte, after a generated header and before one `export { <module> as compiled }` line.
The compiled functions of such a block may not use the runtime, with one exception: a runtime helper that is a
closed function (it names nothing else of the runtime; today integer division and modulo on numbers) is copied
verbatim into the header from the runtime the same compiler emits. Any other use (an unbounded `int`, building a
sequence, datatype `==`, a tuple) is refused, naming the function and the compiled line; only the members the
compiler emits for the runtime's own use (a datatype's `toString` and `equals`, a newtype's `_Is` and
`IntegerRange`) may mention it: nothing a core or its façade runs calls them, and one that names the runtime
would throw. A block's own function is never exempt, whatever its name. Types: a newtype over a literal integer range within the JavaScript safe integers -> `number`, checked to be
an integer in that range in both directions; `bool` -> `boolean`; `seq<T>` -> a readonly array of `T`; a linked
list, a generic datatype of the shape `L<T> = Nil | Cons(head: T, tail: L<T>)` under any names, -> a readonly
array of `T`, converted in a loop in both directions (no other generic datatype has a shape); a datatype
of nullary constructors -> a string union of their names, a one-constructor datatype named like its type -> a
plain object, any other datatype -> an object tagged by `$`; an unknown constructor is a `TypeError` in either
direction. A constructor without fields is built once and shared (compiled datatype values are never changed).
A compiled method of the laws (`method M(...) returns (out: T)`) is exposed with its sequence and plain
parameters only: each `array<T>` parameter is a work array the façade lends, fresh on every call and as long as
the sequence parameter its precondition names (`a.Length == |s|`), so nothing a call left behind reaches the
next. A method's preconditions must be ones the façade establishes or checks: that sizing, `|s| < literal`, or a
call of a compiled predicate on parameters; anything else is refused. `bind(compiled)` binds the façade to another translation of the block; `core` is the checked-in one.

## Wire

The Gateway protocol's value types have one source, `packages/core/wire/Protocol.dfy`: `proof wire --protocol`
writes `packages/gateway/src/protocol/types.ts` (types, decoders and encoders, generated; never edited) and the
iOS app's decoders `packages/ios-app/Core/Generated/Protocol.swift` (the datatypes the source's `// @swift`
lines name and every datatype they reach; an enum a `// @swift-codable` line names, which must have only string
wire values, also takes the standard library's `Codable`, for as long as a hand Codable container holds it: today
`SessionPhase`, inside `SessionSnapshot`, owed back by #2380's slice 7), and `--check` exits 1 when either file is not what the source generates. The Gateway still writes frames with
`JSON.stringify` of the values it builds, so the generated encoders serve the codec tests only and the
decoders are the protocol's validators. A type another module owns (the display contract, the upstream error)
is marked `import=<path>`: types.ts imports it and fails to compile unless it equals the stated shape. The
Swift codec is proven against the TypeScript one in the test below. The iOS app decodes those datatypes with it
(`JSONValue.decodeWire`, which reports a `WireError` as a `DecodingError`; an RPC response goes through
`GatewayResponseDecoding`, which reports that as the method's `invalid_response` failure) and checks their invariants in its
own validators beside each consumer; the protocol types not yet listed are still decoded by hand models (#2380).

`dafny2wire/dafny2wire.mjs` (`proof wire --generate`) turns `// @wire` Dafny datatypes into `wire.ts` and
`Wire.swift` codecs: records; `// @wire enum` (a JSON literal per constructor: `{:wire "x"}`, `{:wire 1}`,
`{:wire true}`, else the constructor name); `// @wire tag=<field>` tagged unions (a tag value may be a string,
number or boolean); `// @wire bykind` unions
split by JSON kind (a nullary constructor is `null`; this is how open JSON values are written). Field types:
`string`, `bool`, `int`/`nat` (safe-range JSON integers), `real` (float64), `seq<T>`, `map<string, T>` (or
`map<E, T>` with E a string enum: only E's values are keys),
`Option<T>` (absent key), `Nullable<T>` (JSON null) and `Absent` (the key never appears); a trailing `_`
escapes a Dafny keyword or a shared destructor name. Canonical JSON: keys in declaration order with the tag
first, no whitespace, JSON.stringify string escaping, ECMAScript Number::toString (`-0` as `0`; non-finite
numbers refused by both encoders). Maps keep JavaScript's property order (array-index keys ascending, then
insertion order; a duplicate key keeps its first position and last value), also when built in Swift, so the
Swift codec parses JSON itself rather than through Foundation; an overflowing number literal (`1e400`)
parses as infinity and is rejected at its path by both decoders. The TypeScript decoders are strict: they
reject unknown and absent-only fields, missing fields, wrong kinds, out-of-range integers and unknown
constructors at a named JSON path. The Swift decoders are tolerant, the iOS decoding policy: unknown fields are
ignored; an absent field, or a null one whose type cannot hold null (not `Nullable<T>`, not a union with a null
constructor), takes its type's default (`""`, `0`, `false`, empty, `null`, the `unknown` value of an enum that
has one, an enum's only value, a record of defaults); an unknown value of an enum with an `unknown` value is
`unknown`. An enum field may declare its own default with Dafny's default-value syntax
(`attention: HomeTaskCheckinAttention := HomeTaskCheckinAttention.none`), a scalar field a literal
(`summaryRevision: int := 0`), and an optional field `Some(<default>)` (`isUnread: Option<bool> := Some(false)`),
which makes it a non-optional Swift field that reads absent as the default and is always written; only the Swift
codec reads a default, so TypeScript stays as declared. A
field with no default (another enum, a union) is still required, and wrong kinds, unknown tags and
unknown map keys are still refused; invariants beyond the shape belong to a validator layer, not the decoder.
Swift declarations are `package`, `Hashable` and `Sendable`, and a record has a `package` memberwise init whose
optional fields default to nil; an enum whose wire values are all strings carries
them as its raw values, `Nullable.value` reads a nullable as an optional, and a `WireMap` subscript reads one key. Limits: Swift refuses a lone UTF-16
surrogate, which JavaScript strings can hold.
