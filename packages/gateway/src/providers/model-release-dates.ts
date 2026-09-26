import aliases from "./model-release-date-aliases.json" with { type: "json" };
import releaseDates from "./model-release-dates.json" with { type: "json" };

/**
 * Vendored model release dates for the picker's Latest rail.
 *
 * The pinned catalog carries no release date, so the vendor facts are snapshotted
 * by scripts/update-model-release-dates.mjs. Snapshots are keyed by the vendor's
 * own `provider/id`; the alias map covers Pi providers whose catalog reuses
 * another vendor's models. A model absent from both is simply undated.
 */
const VENDOR_RELEASE_DATES: Readonly<Record<string, string>> = releaseDates;
const PROVIDER_ALIASES: Readonly<Record<string, string>> = aliases;

/** `YYYY-MM-DD` release date for one catalog model, or undefined when unknown. */
export function modelReleaseDate(provider: string, id: string): string | undefined {
  const exact = VENDOR_RELEASE_DATES[`${provider}/${id}`];
  if (exact !== undefined) return exact;
  const alias = PROVIDER_ALIASES[provider];
  return alias === undefined ? undefined : VENDOR_RELEASE_DATES[`${alias}/${id}`];
}
