import { writeFileSync } from "node:fs";
import { CatalogMetadataIndex } from "../src/sessions/catalog-metadata-index.js";
import { realisticCatalogRows } from "./catalog-metadata-fixture.js";

const [gateway, root, marker, count] = process.argv.slice(2) as [string, string, string, string];
const cuts = [realisticCatalogRows(root, Number(count), 1), realisticCatalogRows(root, Number(count), 2)];
const index = new CatalogMetadataIndex(gateway);
for (let save = 0; ; save += 1) {
  if (!(await index.save(root, cuts[save % 2]!))) throw new Error("crash child save was refused");
  if (save === 0) writeFileSync(marker, "saving");
}
