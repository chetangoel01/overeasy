# Full Recipe: the tick draws itself

Date: September 23, 2026
Branch: `codex/motion-checklist-tick`, one of six motion changes built in
parallel from `codex/motion-bridges`.
Status: **implemented, built and unit-tested; captures follow at integration.**

## Purpose

Ticking off an ingredient or a step in Full Recipe snapped: the circle filled,
the checkmark appeared, the number vanished and the text dimmed in one frame.
The haptic said "done" but the row gave nothing to watch. The row now settles
into its completed state in the native iOS motion language, without changing
what it shows.

## What the cook sees

- Ticking a row draws the checkmark in with the SF Symbols Draw On effect. On
  a step, the number fades out as the check draws.
- The circle's fill and stroke turn to the success colour, and the row's text
  dims to 48% and takes its strikethrough, over the same 150 ms zero-bounce
  snappy curve.
- Unticking plays it back: the check draws out, the number fades in, the
  circle and text return.
- The success haptic is unchanged: it plays only when a row goes from open to
  done, never on unticking.
- Reduce Motion changes the row at once, with the same colours, strikethrough
  and haptic.
- Sizes, colours, identifiers and VoiceOver labels are unchanged.

## Decisions

1. **The animation belongs to the row, keyed on `isCompleted`.** Each row's
   label carries `.animation(completionAnimation, value: isCompleted)`; the
   view model's toggle is called plainly, as before. The press style's scale
   sits outside the label, so its own 0.15 s spring is untouched.
2. **150 ms, press-feedback speed.** The tick answers a tap, so it uses the
   control-press duration rather than the 0.2 s house curve for ordinary
   motion.
3. **One transition for both directions.** `.transition(.symbolEffect(.drawOn))`
   draws the check in on insertion and back out on removal. The step number
   keeps SwiftUI's default fade.
4. **No new test.** There is no new rule or state: the forward-only haptic is
   `LadleFeedbackPolicy.didComplete`, already covered by
   `DesignTokenTests.testFeedbackPolicyOnlyAcknowledgesMeaningfulStateChanges`,
   and the Reduce Motion choice is the house `reduceMotion ? nil : .snappy(…)`
   pattern inline. A test of a modifier's curve would copy the implementation.
   The motion is checked by build and captures.

## Affected components

- `Ladle/Cooking/FullRecipeView.swift`: `completionAnimation`, applied to the
  ingredient and step row labels; the checkmark's Draw On transition in
  `completionIcon(isCompleted:number:)`.
- `DESIGN.md`: the Full Recipe line in the Cooking section.

## Verification

- `git diff --check`: clean.
- `xcodebuild build -scheme Ladle` (Debug, iOS Simulator): succeeded with the
  Share Extension and LadleTimers embedded. No new warnings; the only one is
  the existing unused `viewport` in `WatchView.swift`.
- `xcodebuild test -scheme LadleAllTests -only-testing:LadleTests`: 559 tests,
  1 skipped, 0 failures, including the feedback policy test above.
- LadleCore is untouched, so `swift test --package-path Packages/LadleCore`
  was not run.
- To check at integration, in Full Recipe:
  - The checkmark draws in on tick and out on untick, and the step number
    fades rather than snapping.
  - Circle, strikethrough and 48% dimming move together; the strikethrough
    may cross-fade rather than slide, which is the system's own text change.
  - Ticking the last step still ends cooking at once; the cover may close
    before the check finishes drawing, and that is acceptable.
  - With Reduce Motion on, every change is instant and the haptic still plays
    on tick only.

### Captures

Captures are added at integration.
