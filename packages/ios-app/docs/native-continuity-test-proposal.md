# Native chat continuity test proposal

Status: preserved test-only prototype on `feature/chat-native-continuity-tests`;
**not validated or merge-ready**. The branch starts from historical commit
`f75224c74`, not current main. No simulator, build, or device run was performed
as part of preservation.

## Intent

The additional assertions in `Tests/UI/ChatViewScrollHarnessTests.swift` observe
actual hosted native rows during compaction and tool-group topology changes,
rather than trusting only the chat projection's visibility report. They also
wait for a stable native tail and can attach diagnostic simulator images.

The draft adds `nativeRowSnapshot`, `waitForNativeTailSettlement`, and
`PresentedFrameRecorder.expectNativeContinuity`. Diagnostic `print` calls and
image attachments are investigative aids, not a requirement to retain in a
shipping test suite. No production behavior changes are included.

## Resuming safely

1. Start a new isolated worktree from current main. Locate the current owning
   chat continuity tests; the historical harness may have moved or been split.
2. Check whether current tests already protect native row continuity. Port only
   missing behavioral assertions, not the old harness or obsolete chat code.
3. Replace exploratory logging with bounded failure evidence. Review the exact
   geometry comparison, frame bound, and failure cleanup for flakiness.
4. Load the project iOS and test-confidence skills. Run the focused owning suite
   on the canonical test simulator and use a negative control that actually
   breaks native visibility to establish the assertion's value.

The feature branch preserves the original draft; generated Xcode projects,
simulator artifacts, and build outputs are deliberately excluded. Creating or
retaining this branch does not authorize installation or Gateway transitions.
