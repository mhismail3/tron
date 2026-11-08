// Inventory fixture for tools/proof/tests/wire.test.mjs: shapes the generated wire format cannot carry.
export interface Opaque { value: unknown }
export interface Callback { run(): void }
export interface Mixed { name: string; [key: string]: string }
export type Untagged = { a: string } | { b: number };
export type SameKind = string[] | number[];
export interface Loose { value: object }
export interface Fine { id: string; tags?: string[] }
