// Wire-format fixture for tools/proof/tests/wire.test.mjs (test input; the protocol's own source is P1.6):
// one datatype per shape the Gateway protocol uses.
module WireFixture {
  datatype Option<T> = None | Some(v: T)
  datatype Nullable<T> = Null | NonNull(v: T)
  datatype Absent = Absent

  // @wire bykind
  datatype JsonValue = JNull | JBool(b: bool) | JNum(n: real) | JStr(s: string) | JArr(a: seq<JsonValue>) | JObj(o: map<string, JsonValue>)

  // @wire enum
  datatype Phase = idle | running | {:wire "slot-admission"} slotAdmission

  // @wire enum
  datatype Version = {:wire 1} v1

  // @wire enum
  datatype Yes = {:wire true} yes

  // @wire enum
  datatype Level = {:wire 0} zero | {:wire 2} two | {:wire false} off

  // @wire
  datatype ModelRef = ModelRef(provider: string, id: string)

  // @wire
  datatype Sample = Sample(version: Version, label_: string, count: nat, delta: int, ratio: real, on: bool, phase: Phase, level: Level, tags: seq<string>, models: seq<ModelRef>, limits: map<string, real>, note: Option<string>, parent: Nullable<string>, extra: Option<JsonValue>, owner: Option<ModelRef>, bold: Option<Yes>)

  // @wire tag=type
  datatype Event = {:wire "session.started"} Started(sample: Sample) | Stopped(reason: Absent) | {:wire "chunk"} Chunk(text: string, at: nat)

  // @wire tag=kind
  datatype Part = Text(text: string, arguments_: Absent) | Tool(name: string, arguments: map<string, JsonValue>)

  // @wire
  datatype Frame = Frame(seq_: nat, events: seq<Event>, parts: seq<Part>)
}
