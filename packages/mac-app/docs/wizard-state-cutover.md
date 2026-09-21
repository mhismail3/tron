# Mac wizard state cutover (manual operator command)

The Mac wrapper owns resumable wizard progress at
`<Tron home>/internal/mac/wizard-state.json` as a private version-1 record:

```json
{"step":"install","version":1}
```

The retired preference `tron.mac.wizardStep` is not a second runtime
authority. Startup never reads it, migrates it, or deletes it. If the record is
absent, startup shows Welcome without creating a record; the first explicit
navigation writes the new record. This preserves legacy progress until an
operator stages it and keeps cold-resume behavior (transient steps are clamped
by `WizardState`, while `.onboarded` remains the completion authority).

## Stage, verify, publish

Perform this while the selected wrapper and all wizard writers are stopped.
Use the explicit profile and home identity; never infer one from the current
process. Stable uses the `com.tron.mac` defaults domain and Debug uses
`com.tron.mac.dev`. Replace placeholders only with paths from the approved
maintenance window:

```bash
scripts/tron wizard-migrate stage \
  --profile stable \
  --home <stable-tron-home> \
  --staging <private-wizard-staging>
scripts/tron wizard-migrate verify --staging <private-wizard-staging>
scripts/tron wizard-migrate publish --staging <private-wizard-staging>
# Only after an interrupted publish with a proven destination:
scripts/tron wizard-migrate recover --staging <private-wizard-staging>
```

For the Debug companion, run the same commands with
`--profile debug --home <debug-tron-home>`. The command invokes exactly:

```text
/usr/bin/defaults read com.tron.mac tron.mac.wizardStep
/usr/bin/defaults read com.tron.mac.dev tron.mac.wizardStep
```

Only the command for the selected profile is run. The operator command reads
one owned key, validates it against the current `WizardStep` values, and never
reads or exports the preference domain. `--home` and `--staging` are explicit;
synthetic tests inject a process runner and never invoke `defaults`.

`stage` refuses an existing destination, malformed or newer records, invalid
steps, links, unsafe ownership/modes, and path collisions. It retains
`migration.json` with the exact source domain/key/command, selected step,
destination, completion-marker observation, and phase, plus a private staged
record. `verify` repeats the file and metadata checks. `publish` re-reads the exact legacy key, uses a same-filesystem atomic
no-clobber copy/link with a distinct destination inode, fsyncs the destination
directory, and keeps the immutable staging record and journal as rollback
evidence. If a process stops after destination creation but before journal
publication, `verify` refuses to guess; `recover` re-reads the exact key and
marks the operation published only after matching the staged digest and
identity proof. It does not modify
`internal/run/.onboarded` or remove the old preference.

Do not run `defaults` as a substitute for this command or delete the old key as
part of staging. After activation and verified cold resume, a maintainer may
separately remove the exact owned legacy key using the reviewed macOS procedure;
that cleanup is not automated here. A published staging directory is retained
for rollback evidence and cannot be cleaned by this helper.
