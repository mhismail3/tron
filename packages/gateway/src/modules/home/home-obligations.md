# Maintainer obligations

`obligation` is a Home-only tool over `tron.home-obligation.v1` custom entries in
canonical chapter history, not a database or a Profile todo list. `request` opens a
stable ID with text, optional exact GitHub issue URL, and a verbatim quote of the
current maintainer input. `reported-done` closes the human action on his confirmation;
`verified` records separate successful tool-result evidence from that activation.
Lack of verification never makes a reported-done action owed again. Only `reopened`
from a new maintainer input reopens it. Duplicate IDs cannot recreate closed items.
Home calls `list` before stating what is owed; summaries cannot write or reopen items.

The Gateway binds sources to the actual open user activation and canonical entry IDs,
not caller-supplied actor claims. Workers and result/automation wakes cannot write.
Closing grants no task, approval or external effect. Issue linkage is a reference:
Home records verified closure with issue-close evidence; this tool never closes GitHub
issues or polls their status. Existing Changes, task and approval owners are unchanged.

Writes use native canonical receipt persistence and chapter guards, with a per-tool-call
receipt identity. Reads fold designated chapters in order and validate source entries;
there is no mutable projection cache, migration, live seeding or fallback to summaries.
Malformed history refuses rather than reporting nothing owed. Bounds are 1000 items,
10000 events and a 128 KiB owed response; exceeding them refuses a partial result.
`home-obligations.e2e.test.ts` crosses real Home tool execution, lossy summary compaction,
chapter rollover and cold Gateway restart, preserving native compaction refusal.

