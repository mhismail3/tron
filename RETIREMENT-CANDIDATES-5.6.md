# Settings 5.6 retirement candidates

Tests whose whole subject this slice deletes. They stay in place (the overnight rule bars test
deletions) and fail until the maintainer approves retiring them. No replacement surface carries
the behaviour: worker/tool/run settings and tool selection are edited through the agent's
`settings` tool, not an iOS screen.

| Test | Covered | Subject deleted by |
|---|---|---|
| `packages/ios-app/ViewTests/SheetLayoutViewTests.swift:7` `testHomeSettingsAreOnMainSheet` | Home Settings sheet (`home-manage-settings`) shows worker/tools/run rows inline with Overridden pill, Reset and a deeper Worker models editor | `home-manage-settings` row: ef9ed3d77; `settings-row-*` renderer rows and section links: 4e28d9264, 3dc5bc1dd |
| `packages/ios-app/ViewTests/SheetLayoutViewTests.swift:38` `testSessionCaptionFollowsUntitledSettingsCard` | Session Settings sheet (`chat-settings-link`) caption is the session card's footer, above Repository Overrides | `SessionSettingsView`, `chat-settings-link`, repository overrides: 3dc5bc1dd |
| `packages/ios-app/ViewTests/FiveSheetPolishViewTests.swift:7` `testToolsCountSharesHeaderLine` | Home Settings tools editor (`settings-tools-editor`) puts the "N of N on" count on the Built-in header line | `SettingsToolsEditor`: 4e28d9264; `home-manage-settings`: ef9ed3d77 |
| `packages/ios-app/ViewTests/SixSmallUIRegressionViewTests.swift:7` `testHomeSettingsOrder` | Six-small `home` surface heading order (Workers & delegation, Tools, Connection) | `HostedSixSmallUIFixture` `home` surface (`SessionSettingsView`): 6bf93ebc8, 3dc5bc1dd |
| `packages/ios-app/ViewTests/SixSmallUIRegressionViewTests.swift:23` `testSessionSettingsOrder` | Six-small `session` surface row order (Compaction, Tools, Project Trust, More Settings) | same as above |

Proof: `git grep -F` for `"home-manage-settings"`, `"chat-settings-link"`, `struct SettingsToolsEditor`,
`struct SessionSettingsView` and `settings-section-` finds each in `packages/ios-app/Sources` or `Fixtures`
on main f86454f0e and nowhere on this branch; `git log -S` names the commits above.

Related, outside the brief: `AvailableToolsList` (`Sources/UI/Chat/SessionToolPickerSheet.swift`) lost its
only caller with `SettingsToolsEditor`; delete it with the tools-count test once retirement is approved.
