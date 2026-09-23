# First run: the share step demonstrates itself

Date: September 23, 2026
Branch: `codex/motion-onboarding-share`
Status: **implemented and verified by build and unit tests; captures happen at
integration.**

## Purpose

The first walkthrough step asks the cook to "tap Share and choose Add to
Overeasy", beside a still picture of a post, an arrow and the Add to Overeasy
row. The picture now acts that instruction out once, so the gesture is seen
rather than read, and then goes still again.

## What the cook sees

- Shortly after the share step appears, it plays one short sequence: the
  Share glyph pops up to 1.25× and back, the arrow below it nudges 8 points
  down and back, and the Add to Overeasy row fills with the chosen accent
  while its label and chevron turn to the on-accent colour. The filled row
  holds for 0.6 s, then everything settles back to today's illustration.
  The whole sequence takes under two seconds.
- It plays once each time the share step appears and never loops. The
  walkthrough only moves forward, so within one walkthrough that is once; an
  interrupted walkthrough that resumes after relaunch starts on the share
  step again and plays it again.
- Tapping Next or Skip before it starts cancels it; nothing plays on a step
  that is no longer showing.
- Under Reduce Motion it never plays, and the step is the still illustration
  it has always been.
- Layout, copy and the illustration's combined accessibility label ("Share a
  recipe video, then choose Add to Overeasy") are unchanged. Nothing around
  the illustration moves while it plays.

## Decisions

1. **One `PhaseAnimator` over a `ShareBeat` enum** — rest, tapShare, travel,
   land — driven by a `shareAppearances` counter as its trigger. A trigger
   runs the phases once and returns to the first, so the demonstration cannot
   loop; the counter only ticks when the step appears.
2. **It waits out the step's crossfade.** A `.task(id: step)` sleeps for
   `shareDemonstrationDelay(reduceMotion:)`, then ticks the counter. The delay
   is the step crossfade itself, now the named `stepFade` (0.2 s) that the
   step change and the page dots already used, so the two motions never
   overlap. Leaving the step cancels the task, so a demonstration never
   starts on a step that has gone. The walkthrough's own 0.2 s fade-in from
   the root is the same length, so the first appearance waits it out too.
3. **Reduce Motion is decided in the view,** by that function returning
   `nil`: the trigger never changes and the animator never runs. There is no
   separate animation to switch off.
4. **Every beat is a scale, an offset or a colour change,** none of which
   takes part in layout, so the cards, copy and footer stay put.
5. **The curve is `.snappy(duration: 0.25, extraBounce: 0)`** for every beat,
   a touch longer than the house 0.2 s so each beat reads as one step of the
   gesture. The return to rest carries a 0.6 s delay, which is how the landed
   row holds before settling.
6. **The Share glyph keeps its accent-label colour.** The spec asks the
   tapShare beat to tint it to the accent label, but the glyph already rests
   in that colour, so the beat is the pop alone.
7. **The landed row pairs `accent.intent` with `Label.onAccent`,** the same
   fill and label pairing as a primary button, so it reads as the action the
   cook will choose.
8. **No haptic.** The demonstration is not the cook's own action, and success
   feedback is kept for meaningful forward transitions.
9. **An exception to "no new page entrance choreography".** DESIGN.md's
   Motion and feedback section still says there is none; the integration
   update to that section should name this one-shot, Reduce-Motion-gated
   demonstration as the exception.

## Affected components

- `Ladle/Account/OnboardingWalkthroughView.swift`: `ShareBeat`, `stepFade`,
  `shareDemonstrationDelay(reduceMotion:)`, the `shareAppearances` trigger
  and its `.task(id: step)`, and the `PhaseAnimator` in `shareIllustration`.
  The step change and page-dot animations now read `stepFade` in place of
  their literal 0.2.
- `LadleTests/DesignTokenTests.swift`:
  `testShareStepDemonstratesOnceFadedInAndNeverUnderReduceMotion`.
- `DESIGN.md`, "First run and Share Extension": one bullet.

## Verification

- **Red.** The new test was written first. Run against the parent commit's
  view (`-only-testing:LadleTests/DesignTokenTests`), it fails to compile:
  the view has no `shareDemonstrationDelay` or `stepFade`.
- **Green.** With the change, the same test passes.
- `xcodebuild build -scheme Ladle` for the iOS Simulator builds the app with
  its Share Extension and LadleTimers extension, with no new warnings.
- `xcodebuild test -scheme LadleAllTests -only-testing:LadleTests`: 560 tests,
  1 skipped, 0 failures.
- `git diff --check` is clean.

### Captures

Captures are added at integration: the share step playing on first
appearance, the landed frame in light and dark with a non-default accent, and
the step under Reduce Motion.
