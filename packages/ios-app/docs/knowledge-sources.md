# Research source files

Research sources are ordinary workspace Markdown with original JSON and attachment
files. There is no native Knowledge library, source detail, search or coverage
settings sheet. The dashboard menu keeps Settings, Automations, Apps and New Session.

## Retention

The offline converter preserves every committed source revision, original URI,
metadata/provenance and referenced attachment bytes. A hash manifest links original
IDs/revisions to exact original and exported bytes. Normal file tools read the
Markdown; no iOS catalog, corpus cache, sync owner or manifest reader exists.

## Profile and memory

Profile remains a separate Home surface backed by its active note store. Its
shared presentation identities and form/mutation primitives also serve settings,
uploads and connection setup; those primitives are not a corpus reader.
Home memory, chapters, zoom and memory search keep their existing owners.

## Validation

`TronAccessibilityUITests/testKnowledgeProductIsAbsentFromDashboardAndConnectedServices`
checks route absence with the real native menu and Settings in Light/Dark/large type.
`TronSmokeUITests/testDashboardMenuStaysOpenDuringParentUpdates` keeps the existing
native-menu continuity/selection proof using Automations.

The [offline runbook](../../../docs/development.md#offline-knowledge-retirement)
owns preservation, offline verification and maintainer-only recovery.
