#!/usr/bin/env node
// Purpose: `scripts/tron proof wire --generate <in.dfy> <out-dir>`: one wire source (Dafny datatypes marked
// `// @wire`) -> TypeScript and Swift codecs that produce identical bytes and reject the same inputs.
//
// Source forms (one `// @wire` line directly above each datatype):
//   // @wire                 datatype R = R(a: T, b_: U)          record: a JSON object
//   // @wire enum            datatype E = A | {:wire "b-c"} B     a JSON string, one per constructor
//   // @wire tag=<field>     datatype S = A(x: T) | {:wire "b"} B  tagged union: {"<field>": "<name>", ...fields}
// A constructor's wire name is its {:wire "..."} attribute, else its name; a field's is its name with one
// trailing `_` removed (a Dafny keyword escape: `label_` is "label").
// Field types: string, bool, int (JSON integer in the safe range), nat (same, >= 0), real (a JSON float64
// number), Json (any JSON value), seq<T> (array), map<string, T> (object), Option<T> (Some = key present,
// None = key absent), Nullable<T> (NonNull = value, Null = JSON null), and other @wire datatypes.
//
// Canonical JSON: keys in declaration order (a tag first), no whitespace, strings escaped as
// JSON.stringify does, numbers formatted as ECMAScript Number::toString (-0 as 0); maps and Json objects keep
// JavaScript's property order (array-index keys ascending, then insertion order), which is what a
// TypeScript decoder sees. Decoders reject unknown fields, wrong kinds, non-safe integers and unknown
// constructors, naming the JSON path; Swift parses JSON itself so that order and duplicates (last wins, at
// the first key's position) follow JSON.parse.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function parseWire(src) {
  const types = [];
  const re = /\/\/ @wire(?:[ \t]+(enum|tag=([A-Za-z_][A-Za-z0-9_]*)))?[ \t]*\n\s*datatype\s+(\w+)\s*=([\s\S]*?)(?=\n\s*(?:\/\/ @wire|datatype|\}\s*$)|\n\s*\}\s*$)/g;
  for (const m of src.matchAll(re)) {
    const [, mode, tag, name, rawBody] = m;
    const body = rawBody.trim().replace(/^\|/, "");
    const ctors = splitTop(body, "|").map((c) => c.trim()).filter(Boolean).map((c) => {
      const attr = /^\{:wire\s+"([^"]+)"\}\s*/.exec(c);
      const rest = attr ? c.slice(attr[0].length) : c;
      const p = rest.indexOf("(");
      const cname = (p < 0 ? rest : rest.slice(0, p)).trim();
      const fields = p < 0 ? [] : splitTop(rest.slice(p + 1, rest.lastIndexOf(")")), ",").map((f) => {
        const [n, ...t] = f.split(":");
        return { name: n.trim(), wire: n.trim().replace(/_$/, ""), type: parseType(t.join(":").trim()) };
      });
      return { name: cname, wire: attr ? attr[1] : cname, fields };
    });
    const kind = mode === "enum" ? "enum" : tag ? "tagged" : "record";
    if (kind === "record" && (ctors.length !== 1)) throw new Error(`${name}: a record has one constructor (use tag=<field> for a union)`);
    if (kind === "enum" && ctors.some((c) => c.fields.length)) throw new Error(`${name}: enum constructors take no fields`);
    if (kind === "tagged" && ctors.some((c) => c.fields.some((f) => f.wire === tag))) throw new Error(`${name}: a field is named like the tag ${tag}`);
    types.push({ name, kind, tag, ctors });
  }
  const names = new Set(types.map((t) => t.name));
  const check = (t, where) => {
    if (["seq", "Option", "Nullable"].includes(t.kind)) return check(t.arg, where);
    if (t.kind === "map") { if (t.key.kind !== "string") throw new Error(`${where}: map keys must be string`); return check(t.arg, where); }
    if (!["string", "bool", "int", "nat", "real", "Json"].includes(t.kind) && !names.has(t.kind)) throw new Error(`${where}: unknown type ${t.kind}`);
  };
  for (const ty of types) for (const c of ty.ctors) for (const f of c.fields) check(f.type, `${ty.name}.${c.name}.${f.name}`);
  return types;
}
function splitTop(s, sep) { const out = []; let depth = 0, cur = "", str = false; for (const ch of s) { if (ch === '"') str = !str; if (!str && "(<{".includes(ch)) depth++; if (!str && ")>}".includes(ch)) depth--; if (!str && ch === sep && depth === 0) { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out; }
function parseType(t) {
  const g = /^(\w+)<(.+)>$/.exec(t.trim());
  if (!g) return { kind: t.trim() };
  if (g[1] === "map") { const [k, v] = splitTop(g[2], ","); return { kind: "map", key: parseType(k), arg: parseType(v) }; }
  return { kind: g[1], arg: parseType(g[2]) };
}
const lc = (s) => s[0].toLowerCase() + s.slice(1);
const swiftName = (s) => (/^(default|case|enum|struct|class|let|var|func|in|is|as|self|Type|protocol|init|return|true|false|nil|where|repeat|while|for|if|else|switch|import|public|private|static|extension|operator|throws|try|catch|throw|do|guard|defer|break|continue|fallthrough|inout|internal|open|subscript|typealias|associatedtype|super|any|some)$/.test(s) ? `\`${s}\`` : s);

// ---------------------------------------------------------------- TypeScript
export function emitTs(types, source) {
  const out = [`// GENERATED by tools/proof/dafny2wire from ${source}. Do not edit.`, TS_PRELUDE];
  const tsType = (t) => ({ string: "string", bool: "boolean", int: "number", nat: "number", real: "number", Json: "JsonValue" })[t.kind]
    ?? (t.kind === "seq" ? `ReadonlyArray<${tsType(t.arg)}>` : t.kind === "map" ? `Readonly<Record<string, ${tsType(t.arg)}>>` : t.kind === "Option" ? tsType(t.arg) : t.kind === "Nullable" ? `${tsType(t.arg)} | null` : t.kind);
  const dec = (t, v, p) => ({ string: `str(${v}, ${p})`, bool: `bool(${v}, ${p})`, int: `int(${v}, ${p})`, nat: `nat(${v}, ${p})`, real: `num(${v}, ${p})`, Json: `json(${v}, ${p})` })[t.kind]
    ?? (t.kind === "seq" ? `seq(${v}, ${p}, (x, q) => ${dec(t.arg, "x", "q")})` : t.kind === "map" ? `dict(${v}, ${p}, (x, q) => ${dec(t.arg, "x", "q")})`
      : t.kind === "Nullable" ? `(${v} === null ? null : ${dec(t.arg, v, p)})` : `decode${t.kind}(${v}, ${p})`);
  const enc = (t, v) => ({ string: `JSON.stringify(${v})`, bool: `JSON.stringify(${v})`, int: `JSON.stringify(${v})`, nat: `JSON.stringify(${v})`, real: `encNum(${v})`, Json: `encJson(${v})` })[t.kind]
    ?? (t.kind === "seq" ? `"[" + ${v}.map((x) => ${enc(t.arg, "x")}).join(",") + "]"` : t.kind === "map" ? `encDict(${v}, (x) => ${enc(t.arg, "x")})`
      : t.kind === "Nullable" ? `(${v} === null ? "null" : ${enc(t.arg, v)})` : `encode${t.kind}(${v})`);
  const fieldsType = (c) => c.fields.map((f) => `readonly ${f.wire}${f.type.kind === "Option" ? "?" : ""}: ${tsType(f.type)}`);
  const decFields = (c) => c.fields.map((f) => f.type.kind === "Option"
    ? `...(own(o, "${f.wire}") === undefined ? {} : { ${f.wire}: ${dec(f.type.arg, `own(o, "${f.wire}")`, `p + ".${f.wire}"`)} })`
    : `${f.wire}: ${dec(f.type, `own(o, "${f.wire}")`, `p + ".${f.wire}"`)}`);
  // Each field contributes `,"name":value` (or nothing when an Option is absent); the leading comma is cut.
  const encFields = (c, pre) => c.fields.map((f) => f.type.kind === "Option"
    ? `(${pre}.${f.wire} === undefined ? "" : ',"${f.wire}":' + ${enc(f.type.arg, `${pre}.${f.wire}`)})`
    : `',"${f.wire}":' + ${enc(f.type, `${pre}.${f.wire}`)}`);
  for (const ty of types) {
    if (ty.kind === "enum") {
      out.push(`export type ${ty.name} = ${ty.ctors.map((c) => JSON.stringify(c.wire)).join(" | ")};`,
        `const ${ty.name}Values: ReadonlyArray<string> = ${JSON.stringify(ty.ctors.map((c) => c.wire))};`,
        `export function decode${ty.name}(v: unknown, p = "$"): ${ty.name} { const s = str(v, p); if (!${ty.name}Values.includes(s)) throw new WireError(p, \`unknown value \${JSON.stringify(s)}\`); return s as ${ty.name}; }`,
        `export function encode${ty.name}(v: ${ty.name}): string { return JSON.stringify(v); }`);
    } else if (ty.kind === "record") {
      const c = ty.ctors[0];
      out.push(`export interface ${ty.name} { ${fieldsType(c).join("; ")} }`,
        `export function decode${ty.name}(v: unknown, p = "$"): ${ty.name} {`, `  const o = obj(v, p);`, `  only(o, p, ${JSON.stringify(c.fields.map((f) => f.wire))});`,
        `  return { ${decFields(c).join(", ")} };`, `}`,
        `export function encode${ty.name}(v: ${ty.name}): string {`, c.fields.length ? `  return "{" + (${encFields(c, "v").join(" + ")}).slice(1) + "}";` : `  return "{}";`, `}`);
    } else {
      out.push(`export type ${ty.name} =\n${ty.ctors.map((c) => `  | { readonly ${ty.tag}: ${JSON.stringify(c.wire)}${c.fields.length ? "; " : ""}${fieldsType(c).join("; ")} }`).join("\n")};`,
        `export function decode${ty.name}(v: unknown, p = "$"): ${ty.name} {`, `  const o = obj(v, p);`, `  switch (own(o, ${JSON.stringify(ty.tag)})) {`,
        ...ty.ctors.map((c) => `    case ${JSON.stringify(c.wire)}: only(o, p, ${JSON.stringify([ty.tag, ...c.fields.map((f) => f.wire)])}); return { ${ty.tag}: ${JSON.stringify(c.wire)}${c.fields.length ? ", " : ""}${decFields(c).join(", ")} };`),
        `    default: throw new WireError(p + ".${ty.tag}", \`unknown variant \${JSON.stringify(own(o, ${JSON.stringify(ty.tag)}))}\`);`, `  }`, `}`,
        `export function encode${ty.name}(v: ${ty.name}): string {`, `  switch (v.${ty.tag}) {`,
        ...ty.ctors.map((c) => `    case ${JSON.stringify(c.wire)}: return ${JSON.stringify(`{"${ty.tag}":${JSON.stringify(c.wire)}`)}${c.fields.length ? " + " + encFields(c, "v").join(" + ") : ""} + "}";`),
        `  }`, `}`);
    }
  }
  return `${out.join("\n")}\n`;
}
const TS_PRELUDE = `export class WireError extends Error { readonly path: string; constructor(path: string, message: string) { super(\`\${path}: \${message}\`); this.path = path; } }
export type JsonValue = null | boolean | number | string | ReadonlyArray<JsonValue> | { readonly [key: string]: JsonValue };
const obj = (v: unknown, p: string): Record<string, unknown> => { if (typeof v !== "object" || v === null || Array.isArray(v)) throw new WireError(p, "expected object"); return v as Record<string, unknown>; };
const str = (v: unknown, p: string): string => { if (typeof v !== "string") throw new WireError(p, "expected string"); return v; };
const bool = (v: unknown, p: string): boolean => { if (typeof v !== "boolean") throw new WireError(p, "expected boolean"); return v; };
const num = (v: unknown, p: string): number => { if (typeof v !== "number" || !Number.isFinite(v)) throw new WireError(p, "expected number"); return v; };
const int = (v: unknown, p: string): number => { if (!Number.isSafeInteger(v)) throw new WireError(p, "expected integer"); return v as number; };
const nat = (v: unknown, p: string): number => { if (!Number.isSafeInteger(v) || (v as number) < 0) throw new WireError(p, "expected natural number"); return v as number; };
const seq = <T>(v: unknown, p: string, f: (x: unknown, p: string) => T): T[] => { if (!Array.isArray(v)) throw new WireError(p, "expected array"); return v.map((x, i) => f(x, \`\${p}[\${i}]\`)); };
const dict = <T>(v: unknown, p: string, f: (x: unknown, p: string) => T): Record<string, T> => { const o = obj(v, p); const r: Record<string, T> = {}; for (const k of Object.keys(o)) Object.defineProperty(r, k, { value: f(o[k], \`\${p}[\${JSON.stringify(k)}]\`), enumerable: true, writable: true, configurable: true }); return r; };
const json = (v: unknown, p: string): JsonValue => { if (v === null || typeof v === "boolean" || typeof v === "string") return v; if (typeof v === "number") return num(v, p); if (Array.isArray(v)) return v.map((x, i) => json(x, \`\${p}[\${i}]\`)); return dict(v, p, json); };
// An own property only: inherited names (constructor, toString, __proto__) are never fields.
const own = (o: Record<string, unknown>, k: string): unknown => (Object.hasOwn(o, k) ? o[k] : undefined);
const only = (o: Record<string, unknown>, p: string, keys: string[]): void => { for (const k of Object.keys(o)) if (!keys.includes(k)) throw new WireError(p, \`unknown field \${JSON.stringify(k)}\`); };
const encNum = (v: number): string => JSON.stringify(v);
const encDict = <T>(v: Readonly<Record<string, T>>, f: (x: T) => string): string => "{" + Object.keys(v).map((k) => JSON.stringify(k) + ":" + f(v[k] as T)).join(",") + "}";
const encJson = (v: JsonValue): string => (v === null || typeof v !== "object" ? JSON.stringify(v) : Array.isArray(v) ? "[" + v.map(encJson).join(",") + "]" : encDict(v as Record<string, JsonValue>, encJson));`;

// ---------------------------------------------------------------- Swift
export function emitSwift(types, source) {
  const out = [`// GENERATED by tools/proof/dafny2wire from ${source}. Do not edit.`, SWIFT_PRELUDE];
  const swType = (t) => ({ string: "String", bool: "Bool", int: "Int", nat: "Int", real: "Double", Json: "JSONValue" })[t.kind]
    ?? (t.kind === "seq" ? `[${swType(t.arg)}]` : t.kind === "map" ? `WireMap<${swType(t.arg)}>` : t.kind === "Option" ? `${swType(t.arg)}?` : t.kind === "Nullable" ? `Nullable<${swType(t.arg)}>` : t.kind);
  const dec = (t, v, p) => ({ string: `try wStr(${v}, ${p})`, bool: `try wBool(${v}, ${p})`, int: `try wInt(${v}, ${p}, nat: false)`, nat: `try wInt(${v}, ${p}, nat: true)`, real: `try wNum(${v}, ${p})`, Json: `${v}` })[t.kind]
    ?? (t.kind === "seq" ? `try wSeq(${v}, ${p}) { x, q in ${dec(t.arg, "x", "q")} }` : t.kind === "map" ? `try wDict(${v}, ${p}) { x, q in ${dec(t.arg, "x", "q")} }`
      : t.kind === "Nullable" ? `try wNullable(${v}) { x in ${dec(t.arg, "x", p)} }` : `try ${t.kind}.decode(${v}, ${p})`);
  const enc = (t, v) => ({ string: `wEscape(${v})`, bool: `(${v} ? "true" : "false")`, int: `String(${v})`, nat: `String(${v})`, real: `wFormat(${v})`, Json: `${v}.encode()` })[t.kind]
    ?? (t.kind === "seq" ? `"[" + ${v}.map { ${enc(t.arg, "$0")} }.joined(separator: ",") + "]"` : t.kind === "map" ? `${v}.encode { ${enc(t.arg, "$0")} }`
      : t.kind === "Nullable" ? `${v}.encode { ${enc(t.arg, "$0")} }` : `${v}.encode()`);
  const decField = (f) => {
    const at = `o.value("${f.wire}")`;
    if (f.type.kind === "Option") return `${swiftName(f.wire)}: ${at} == nil ? nil : ${dec(f.type.arg, `${at}!`, `p + ".${f.wire}"`)}`;
    return `${swiftName(f.wire)}: ${dec(f.type, `try wPresent(${at}, p + ".${f.wire}")`, `p + ".${f.wire}"`)}`;
  };
  const encField = (f, pre) => f.type.kind === "Option"
    ? `(${pre}${swiftName(f.wire)} == nil ? "" : ",\\"${f.wire}\\":" + ${enc(f.type.arg, `${pre}${swiftName(f.wire)}!`)})`
    : `",\\"${f.wire}\\":" + ${enc(f.type, `${pre}${swiftName(f.wire)}`)}`;
  const sw = (s) => JSON.stringify(s);
  for (const ty of types) {
    if (ty.kind === "enum") {
      out.push(`public enum ${ty.name}: String, Equatable {`, ...ty.ctors.map((c) => `  case ${swiftName(lc(c.name))} = ${sw(c.wire)}`),
        `  public static func decode(_ v: JSONValue, _ p: String = "$") throws -> ${ty.name} { let s = try wStr(v, p); guard let e = ${ty.name}(rawValue: s) else { throw WireError(path: p, message: "unknown value") }; return e }`,
        `  public func encode() -> String { wEscape(rawValue) }`, `}`);
    } else if (ty.kind === "record") {
      const c = ty.ctors[0];
      out.push(`public struct ${ty.name}: Equatable {`, ...c.fields.map((f) => `  public let ${swiftName(f.wire)}: ${swType(f.type)}`),
        `  public static func decode(_ v: JSONValue, _ p: String = "$") throws -> ${ty.name} {`, `    let o = try wObj(v, p)`, `    try wOnly(o, p, ${sw(c.fields.map((f) => f.wire))})`,
        `    return ${ty.name}(${c.fields.map(decField).join(", ")})`, `  }`,
        c.fields.length ? `  public func encode() -> String { "{" + String((${c.fields.map((f) => encField(f, "self.")).join(" + ")}).dropFirst()) + "}" }` : `  public func encode() -> String { "{}" }`, `}`);
    } else {
      out.push(`public indirect enum ${ty.name}: Equatable {`,
        ...ty.ctors.map((c) => `  case ${swiftName(lc(c.name))}${c.fields.length ? `(${c.fields.map((f) => `${swiftName(f.wire)}: ${swType(f.type)}`).join(", ")})` : ""}`),
        `  public static func decode(_ v: JSONValue, _ p: String = "$") throws -> ${ty.name} {`, `    let o = try wObj(v, p)`,
        `    switch o.value(${sw(ty.tag)}) {`,
        ...ty.ctors.map((c) => `    case .string(${sw(c.wire)})?: try wOnly(o, p, ${sw([ty.tag, ...c.fields.map((f) => f.wire)])}); return .${swiftName(lc(c.name))}${c.fields.length ? `(${c.fields.map(decField).join(", ")})` : ""}`),
        `    default: throw WireError(path: p + ".${ty.tag}", message: "unknown variant")`, `    }`, `  }`,
        `  public func encode() -> String {`, `    switch self {`,
        ...ty.ctors.map((c) => `    case .${swiftName(lc(c.name))}${c.fields.length ? `(${c.fields.map((f) => `let ${swiftName(f.wire)}`).join(", ")})` : ""}: return "{\\"${ty.tag}\\":" + wEscape(${sw(c.wire)})${c.fields.length ? " + " + c.fields.map((f) => encField({ ...f, wire: f.wire }, "")).join(" + ") : ""} + "}"`),
        `    }`, `  }`, `}`);
    }
  }
  return `${out.join("\n")}\n`;
}
const SWIFT_PRELUDE = String.raw`import Foundation

public struct WireError: Error, CustomStringConvertible { public let path: String; public let message: String; public var description: String { "\(path): \(message)" } }

/// A parsed JSON value. Objects keep JavaScript's property order (array-index keys ascending, then
/// insertion order; a duplicate key keeps its first position and its last value), as JSON.parse does.
public indirect enum JSONValue: Equatable {
  case null, bool(Bool), number(Double), string(String), array([JSONValue]), object(WireObject)
  public func encode() -> String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let d): return wFormat(d)
    case .string(let s): return wEscape(s)
    case .array(let a): return "[" + a.map { $0.encode() }.joined(separator: ",") + "]"
    case .object(let o): return "{" + o.entries.map { wEscape($0.0) + ":" + $0.1.encode() }.joined(separator: ",") + "}"
    }
  }
}
public struct WireObject: Equatable {
  public private(set) var entries: [(String, JSONValue)] = []
  public init() {}
  public static func == (a: WireObject, b: WireObject) -> Bool { a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } }
  public func value(_ key: String) -> JSONValue? { entries.first { $0.0 == key }?.1 }
  public mutating func set(_ key: String, _ value: JSONValue) {
    if let i = entries.firstIndex(where: { $0.0 == key }) { entries[i].1 = value; return }
    if let n = wArrayIndex(key) {
      let i = entries.firstIndex { e in wArrayIndex(e.0).map { $0 > n } ?? true } ?? entries.count
      entries.insert((key, value), at: i)
    } else { entries.append((key, value)) }
  }
}
/// A JSON object with values of one type, in JavaScript's property order.
public struct WireMap<T: Equatable>: Equatable {
  public let entries: [(String, T)]
  public init(_ entries: [(String, T)]) { self.entries = entries }
  public static func == (a: WireMap, b: WireMap) -> Bool { a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } }
  public func encode(_ f: (T) -> String) -> String { "{" + entries.map { wEscape($0.0) + ":" + f($0.1) }.joined(separator: ",") + "}" }
}
public enum Nullable<T: Equatable>: Equatable {
  case null, nonNull(T)
  public func encode(_ f: (T) -> String) -> String { if case .nonNull(let v) = self { return f(v) }; return "null" }
}
/// A canonical array index (0 ..< 2^32 - 1, no leading zeros): such keys come first, ascending, in JS objects.
func wArrayIndex(_ k: String) -> UInt32? {
  guard let n = UInt32(k), n != UInt32.max, String(n) == k else { return nil }
  return n
}

// JSON parser (RFC 8259), producing JSONValue with JavaScript object order.
public func wParse(_ text: String) throws -> JSONValue {
  var p = JSONParser(Array(text.utf8))
  p.space()
  let v = try p.value()
  p.space()
  guard p.i == p.b.count else { throw WireError(path: "$", message: "trailing characters") }
  return v
}
struct JSONParser {
  let b: [UInt8]; var i = 0
  init(_ b: [UInt8]) { self.b = b }
  mutating func space() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
  func fail() -> WireError { WireError(path: "$", message: "invalid JSON at byte \(i)") }
  mutating func literal(_ s: String, _ v: JSONValue) throws -> JSONValue {
    let u = Array(s.utf8); guard i + u.count <= b.count, Array(b[i ..< i + u.count]) == u else { throw fail() }
    i += u.count; return v
  }
  mutating func value() throws -> JSONValue {
    guard i < b.count else { throw fail() }
    switch b[i] {
    case UInt8(ascii: "n"): return try literal("null", .null)
    case UInt8(ascii: "t"): return try literal("true", .bool(true))
    case UInt8(ascii: "f"): return try literal("false", .bool(false))
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "["):
      i += 1; space(); var a: [JSONValue] = []
      if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
      while true { space(); a.append(try value()); space(); guard i < b.count else { throw fail() }; if b[i] == UInt8(ascii: ",") { i += 1; continue }; if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }; throw fail() }
    case UInt8(ascii: "{"):
      i += 1; space(); var o = WireObject()
      if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
      while true {
        space(); guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail() }
        let k = try string(); space(); guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail() }; i += 1; space()
        o.set(k, try value()); space(); guard i < b.count else { throw fail() }
        if b[i] == UInt8(ascii: ",") { i += 1; continue }; if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }; throw fail()
      }
    default: return .number(try number())
    }
  }
  mutating func number() throws -> Double {
    let s = i
    if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
    guard i < b.count, (0x30...0x39).contains(b[i]) else { throw fail() }
    if b[i] == 0x30 { i += 1 } else { while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 } }
    if i < b.count, b[i] == UInt8(ascii: ".") { i += 1; guard i < b.count, (0x30...0x39).contains(b[i]) else { throw fail() }; while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 } }
    if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
      i += 1; if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
      guard i < b.count, (0x30...0x39).contains(b[i]) else { throw fail() }; while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
    }
    guard let d = Double(String(decoding: b[s ..< i], as: UTF8.self)), d.isFinite else { throw fail() }
    return d
  }
  mutating func hex4() throws -> UInt32 {
    guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i ..< i + 4], as: UTF8.self), radix: 16) else { throw fail() }
    i += 4; return v
  }
  mutating func string() throws -> String {
    i += 1; var out = [UInt8]()
    while true {
      guard i < b.count else { throw fail() }
      let c = b[i]
      if c == UInt8(ascii: "\"") { i += 1; break }
      if c < 0x20 { throw fail() }
      if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
      i += 1; guard i < b.count else { throw fail() }
      let e = b[i]; i += 1
      switch e {
      case UInt8(ascii: "\""): out.append(0x22)
      case UInt8(ascii: "\\"): out.append(0x5C)
      case UInt8(ascii: "/"): out.append(0x2F)
      case UInt8(ascii: "b"): out.append(0x08)
      case UInt8(ascii: "f"): out.append(0x0C)
      case UInt8(ascii: "n"): out.append(0x0A)
      case UInt8(ascii: "r"): out.append(0x0D)
      case UInt8(ascii: "t"): out.append(0x09)
      case UInt8(ascii: "u"):
        var u = try hex4()
        if (0xD800...0xDBFF).contains(u) {
          // A lone surrogate is not representable in a Swift String: refused (TS keeps it; see README).
          guard i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else { throw WireError(path: "$", message: "lone surrogate") }
          i += 2; let lo = try hex4(); guard (0xDC00...0xDFFF).contains(lo) else { throw WireError(path: "$", message: "lone surrogate") }
          u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
        } else if (0xDC00...0xDFFF).contains(u) { throw WireError(path: "$", message: "lone surrogate") }
        out.append(contentsOf: Array(String(Character(Unicode.Scalar(u)!)).utf8))
      default: throw fail()
      }
    }
    guard let s = String(bytes: out, encoding: .utf8) else { throw fail() }
    return s
  }
}

/// JSON.stringify string escaping.
public func wEscape(_ s: String) -> String {
  var r = "\""
  for u in s.unicodeScalars {
    switch u {
    case "\"": r += "\\\""
    case "\\": r += "\\\\"
    case "\n": r += "\\n"
    case "\r": r += "\\r"
    case "\t": r += "\\t"
    case "\u{08}": r += "\\b"
    case "\u{0C}": r += "\\f"
    default: if u.value < 0x20 { r += String(format: "\\u%04x", u.value) } else { r.unicodeScalars.append(u) }
    }
  }
  return r + "\""
}
/// ECMAScript Number::toString for finite doubles: Swift's shortest round-trip digits, laid out by JS rules.
public func wFormat(_ d: Double) -> String {
  if d == 0 { return "0" }
  if d < 0 { return "-" + wFormat(-d) }
  // Swift's description is the shortest round-trip decimal; take its digits and decimal exponent.
  let s = "\(d)"
  var mantissa = s, exponent = 0
  if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) { mantissa = String(s[..<e]); exponent = Int(s[s.index(after: e)...])! }
  var digits = mantissa.replacingOccurrences(of: ".", with: "")
  let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
  var n = point + exponent
  while digits.hasPrefix("0") { digits.removeFirst(); n -= 1 }
  while digits.hasSuffix("0") { digits.removeLast() }
  let k = digits.count
  if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
  if 0 < n && n <= 21 { let i = digits.index(digits.startIndex, offsetBy: n); return String(digits[..<i]) + "." + String(digits[i...]) }
  if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
  let e = n - 1, sign = e < 0 ? "-" : "+"
  let head = String(digits.first!), tail = String(digits.dropFirst())
  return head + (tail.isEmpty ? "" : "." + tail) + "e" + sign + String(abs(e))
}
func wObj(_ v: JSONValue, _ p: String) throws -> WireObject { guard case .object(let o) = v else { throw WireError(path: p, message: "expected object") }; return o }
func wPresent(_ v: JSONValue?, _ p: String) throws -> JSONValue { guard let v else { throw WireError(path: p, message: "missing") }; return v }
func wStr(_ v: JSONValue, _ p: String) throws -> String { guard case .string(let s) = v else { throw WireError(path: p, message: "expected string") }; return s }
func wBool(_ v: JSONValue, _ p: String) throws -> Bool { guard case .bool(let b) = v else { throw WireError(path: p, message: "expected boolean") }; return b }
func wNum(_ v: JSONValue, _ p: String) throws -> Double { guard case .number(let d) = v else { throw WireError(path: p, message: "expected number") }; return d }
func wInt(_ v: JSONValue, _ p: String, nat: Bool) throws -> Int {
  guard case .number(let d) = v, d == d.rounded(), abs(d) <= 9007199254740991, !nat || d >= 0 else { throw WireError(path: p, message: nat ? "expected natural number" : "expected integer") }
  return Int(d)
}
func wSeq<T>(_ v: JSONValue, _ p: String, _ f: (JSONValue, String) throws -> T) throws -> [T] { guard case .array(let a) = v else { throw WireError(path: p, message: "expected array") }; return try a.enumerated().map { try f($0.element, "\(p)[\($0.offset)]") } }
func wDict<T>(_ v: JSONValue, _ p: String, _ f: (JSONValue, String) throws -> T) throws -> WireMap<T> { let o = try wObj(v, p); return WireMap(try o.entries.map { ($0.0, try f($0.1, "\(p)[\(wEscape($0.0))]")) }) }
func wNullable<T>(_ v: JSONValue, _ f: (JSONValue) throws -> T) throws -> Nullable<T> { if case .null = v { return .null }; return .nonNull(try f(v)) }
func wOnly(_ o: WireObject, _ p: String, _ keys: [String]) throws { for (k, _) in o.entries where !keys.contains(k) { throw WireError(path: p, message: "unknown field \(wEscape(k))") } }`;

export function generate(input, outDir) {
  const types = parseWire(readFileSync(input, "utf8"));
  mkdirSync(outDir, { recursive: true });
  const ts = emitTs(types, basename(input)), swift = emitSwift(types, basename(input));
  writeFileSync(join(outDir, "wire.ts"), ts);
  writeFileSync(join(outDir, "Wire.swift"), swift);
  return { types: types.map((t) => t.name), tsLines: ts.split("\n").length, swiftLines: swift.split("\n").length };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [flag, input, outDir] = process.argv.slice(2);
  if (flag !== "--generate" || !input || !outDir) { console.error("usage: scripts/tron proof wire --generate <in.dfy> <out-dir>"); process.exitCode = 2; }
  else {
    try { console.log(JSON.stringify(generate(input, outDir))); }
    catch (error) { console.error(`proof wire: ${error.message}`); process.exitCode = 2; }
  }
}
