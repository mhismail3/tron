// Wire-format fixture for tools/proof/tests/wire.test.mjs (test input; the protocol's own source is P1.6):
// one datatype per shape the Gateway protocol uses.
module WireFixture {
  datatype Option<T> = None | Some(v: T)
  datatype Nullable<T> = Null | NonNull(v: T)
  // Any JSON value (the generator's built-in Json).
  datatype Json = JNull | JBool(b: bool) | JNum(r: real) | JStr(s: string) | JArr(a: seq<Json>) | JObj(o: seq<(string, Json)>)

  // @wire enum
  datatype Phase = idle | running | {:wire "slot-admission"} slotAdmission

  // @wire
  datatype ModelRef = ModelRef(provider: string, id: string)

  // @wire
  datatype Sample = Sample(label_: string, count: nat, delta: int, ratio: real, on: bool, phase: Phase, tags: seq<string>, models: seq<ModelRef>, limits: map<string, real>, note: Option<string>, parent: Nullable<string>, extra: Option<Json>, owner: Option<ModelRef>)

  // @wire tag=type
  datatype Event = {:wire "session.started"} Started(sample: Sample) | Stopped | {:wire "chunk"} Chunk(text: string, at: nat)

  // @wire tag=kind
  datatype Part = Text(text: string) | Tool(name: string, arguments: map<string, Json>)

  // @wire
  datatype Frame = Frame(seq_: nat, events: seq<Event>, parts: seq<Part>)
}
