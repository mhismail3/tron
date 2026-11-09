// The capability strings `hello`/`system.info` advertise. Values, not wire types, so they live
// beside the generated protocol types (types.ts) rather than in their Dafny source.

/** The capability string `hello`/`system.info` advertise for Tron Home. */
export const HOME_CAPABILITY = "home.v1";
/** Native browser reads are separately gated; older home.v1 servers lack them. */
export const HOME_MEMORY_VIEW_CAPABILITY = "home-memory-view.v1";
/** The full chapter-list read (#740); older home.v1 servers lack it. */
export const HOME_CHAPTER_LIST_CAPABILITY = "home-chapter-list.v1";
/** The learned-profile read (`home.profileList`); advertised only with a Knowledge owner. */
export const HOME_PROFILE_LIST_CAPABILITY = "home-profile-list.v1";
/** The maintainer's learned-profile changes (`home.profileChange`, profile entries in
 * `settings.undo`); advertised with `home-profile-list.v1`. Older Gateways keep the
 * Profile sheet read-only. */
export const HOME_PROFILE_EDIT_CAPABILITY = "home-profile-edit.v1";
