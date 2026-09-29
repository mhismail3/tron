export const RELEASE_DATE_SOURCE = "https://models.dev/api.json";
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MONTH = /^\d{4}-\d{2}$/;

export function normalizeReleaseDate(value) {
  if (typeof value !== "string") return undefined;
  if (DAY.test(value)) return value;
  return MONTH.test(value) ? `${value}-01` : undefined;
}

/** Extract normalized provider/id facts from a models.dev payload. */
export function releaseDatesFromCatalog(catalog, providers, aliases = {}) {
  const coverage = new Set(providers);
  for (const target of Object.values(aliases)) if (typeof target === "string") coverage.add(target);
  const dates = {};
  const unknown = [];
  for (const provider of coverage) {
    const models = catalog?.[provider]?.models;
    if (!models || typeof models !== "object" || Array.isArray(models)) continue;
    for (const [id, model] of Object.entries(models)) {
      const value = normalizeReleaseDate(model?.release_date);
      if (value !== undefined) dates[`${provider}/${id}`] = value;
      else if (model?.release_date != null && unknown.length < 3) unknown.push(`${provider}/${id}`);
    }
  }
  return { dates, providers: coverage.size, unknown };
}
