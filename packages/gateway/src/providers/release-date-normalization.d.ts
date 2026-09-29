export const RELEASE_DATE_SOURCE: string;
export function normalizeReleaseDate(value: unknown): string | undefined;
export function releaseDatesFromCatalog(
  catalog: unknown,
  providers: Iterable<string>,
  aliases?: Record<string, string>,
): { dates: Record<string, string>; providers: number; unknown: string[] };
