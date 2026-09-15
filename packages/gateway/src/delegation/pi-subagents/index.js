import { createJiti } from "jiti";

// Source-tree entrypoint for Node 22 qualification. Release builds use the
// emitted ESM entrypoint; jiti resolves the TypeScript source's NodeNext .js
// specifiers without producing a second implementation.
const sourceModule = await createJiti(import.meta.url).import("./index.ts");
export default sourceModule.default;
