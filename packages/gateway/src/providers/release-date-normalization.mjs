export const RELEASE_DATE_SOURCE = "https://models.dev/api.json";
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MONTH = /^\d{4}-\d{2}$/;

export function normalizeReleaseDate(value) {
  if (typeof value !== "string") return undefined;
  const normalized = DAY.test(value) ? value : MONTH.test(value) ? `${value}-01` : undefined;
  if (normalized === undefined) return undefined;
  const date = new Date(`${normalized}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === normalized ? normalized : undefined;
}

/** Extract normalized provider/id facts from a models.dev payload. */
export function releaseDatesFromCatalog(catalog, providers, aliases = {}) {
  const coverage = new Set(providers);
  for (const target of Object.values(aliases)) if (typeof target === "string") coverage.add(target);
  const dates = {};
  const unknown = [];
  let unrecognizedDateCount = 0;
  for (const provider of coverage) {
    const models = catalog?.[provider]?.models;
    if (!models || typeof models !== "object" || Array.isArray(models)) continue;
    for (const [id, model] of Object.entries(models)) {
      const value = normalizeReleaseDate(model?.release_date);
      if (value !== undefined) dates[`${provider}/${id}`] = value;
      else if (model?.release_date != null) {
        unrecognizedDateCount++;
        if (unknown.length < 3) unknown.push(`${provider}/${id}`);
      }
    }
  }
  return { dates, providers: coverage.size, unknown, unrecognizedDateCount };
}
