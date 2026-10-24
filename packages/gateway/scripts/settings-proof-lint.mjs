import { fileURLToPath } from "node:url";

const trustedModule = fileURLToPath(new URL("../src/kernel/settings/settings-change.ts", import.meta.url)).replaceAll("\\", "/");

/** Syntactic cast guard for the settings admission brand. Not a TS soundness claim:
 * any, JS, mutation/spread of an admitted plan and indirect conditional types can
 * still escape it. The real authorization checks must remain at runtime. */
export default {
  meta: { name: "settings-proof" },
  rules: {
    "no-forged-plan": {
      meta: { type: "problem", schema: [], messages: { forged: "Only settings-change.ts may assert an admitted Planned capability." } },
      create(context) {
        const file = context.filename.replaceAll("\\", "/");
        if (file === trustedModule) return {};
        const names = new Set();
        const aliases = [];
        const assertions = [];
        function containsProof(node) {
          if (!node || typeof node !== "object") return false;
          if (node.type === "Identifier") return names.has(node.name);
          if (node.type === "TSQualifiedName" && node.right.name === "Planned") return true;
          return Object.entries(node).some(([key, value]) => key !== "parent" && (Array.isArray(value)
            ? value.some(containsProof) : value && typeof value === "object" && containsProof(value)));
        }
        return {
          ImportDeclaration(node) {
            if (!node.source.value.endsWith("settings-change.js")) return;
            for (const specifier of node.specifiers) {
              if (specifier.type === "ImportSpecifier" && specifier.imported.name === "Planned") names.add(specifier.local.name);
            }
          },
          TSTypeAliasDeclaration(node) { aliases.push(node); },
          TSAsExpression(node) { assertions.push(node); },
          TSTypeAssertion(node) { assertions.push(node); },
          "Program:exit"() {
            let changed;
            do {
              changed = false;
              for (const alias of aliases) if (!names.has(alias.id.name) && containsProof(alias.typeAnnotation)) {
                names.add(alias.id.name); changed = true;
              }
            } while (changed);
            for (const node of assertions) if (containsProof(node.typeAnnotation)) context.report({ node, messageId: "forged" });
          },
        };
      },
    },
  },
};
