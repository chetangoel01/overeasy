# Servings: the count and the amounts roll

Date: September 23, 2026
Branch: `codex/motion-servings-roll`, one of six motion changes integrated on
`codex/motion-bridges`.

## Purpose

Stepping servings on recipe detail swapped the count and every ingredient
amount in a single frame. A cook who taps plus while looking at the list had
nothing to tell them which lines moved, or which way. The numbers now roll,
the native way iOS changes a figure in place.

## What the cook sees

- The count on the metadata band rolls up when it goes up and down when it
  goes down: 4 to 5 rolls up, 5 to 4 rolls down.
- Each ingredient row rolls with it, in the same direction and the same
  animation. Only the characters that change roll. When "1 lb ground beef"
  becomes "1.25 lb ground beef", the name slides over to make room instead of
  fading.
- Reset rolls back too, down from 6 to 4 or up from 2 to 4, so going back
  reads as a change of count rather than a jump.
- A row's "Not scaled" aside fades in with the first step away from the
  recipe's own count and fades out when the count returns to it. "servings ·
  Reset" on the band's last line appears and leaves in the same animation.
- Reduce Motion: the same values change at once. Nothing rolls, fades or
  slides, and the labels and "Not scaled" asides still change.
- VoiceOver is unchanged. The stepper still reads its own value, and the
  settled announcement ("Scaled to 6 servings. Ingredient amounts updated." or
  "Back to the recipe as written.") still comes once, a second after the last
  step.

## Decisions

1. **Direction comes from the value.** Both texts use
   `.contentTransition(.numericText(value:))`. A bare `.numericText()` always
   rolls up, so stepping down would look like stepping up. The count's value
   is the servings. A row's value is the page's factor, which rises and falls
   with the count because it is the count over the recipe's own yield.
2. **Unscaled is a factor of one, not nothing.** `IngredientList.factor` is
   `scaledBy ?? 1`, the same factor the row text was already written at. If
   the unscaled page counted as zero, stepping 3 to 4 servings would roll the
   amounts down while the count rolled up. One value now does both jobs, so
   the roll cannot disagree with the text.
3. **The animation lives in the band.** `RecipeMetadataBand.countChange` is
   `reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0)`, the house
   curve. `step(_:by:)` and Reset apply it with `withAnimation`. Both the band
   and the list read the same `RecipeScaling` state from `RecipeDetailView`,
   so every change of count lands in one transaction. `RecipeScaling` stays a
   plain value and knows nothing about motion.
4. **Reset animates too.** The motion-lab mock snapped Reset. The spec
   overrides it, because going back is a change of count like any other.
5. **Announcements stay outside the animation.** `announceOnceSettled` runs
   after the `withAnimation` block, exactly where it ran before.
6. **No haptic or success feedback.** A step is an adjustment, not a
   completion, so `LadleFeedbackPolicy` is not involved.
7. **No new test.** This change adds no rule. The Reduce Motion ternary is
   the house rule, written as it is in Focus Mode and the estimates
   disclosure. The factor of one is the unscaled rule the rows already
   followed. `RecipeScalingTests` already covers the multiplier following the
   count and returning to `nil` at the recipe's own count. The roll itself is
   visual, so the build and on-device captures verify it.

## Affected components

- `Ladle/RecipeDetail/RecipeMetadataBand.swift`: reads Reduce Motion; adds
  the numeric content transition to the count; puts `step(_:by:)` and Reset
  inside `countChange`.
- `Ladle/RecipeDetail/IngredientList.swift`: adds a private `factor`; adds
  the numeric content transition to each row's text. The reimport sheet's
  list never scales, so its factor stays one and nothing rolls.
- `DESIGN.md`: one sentence in the servings bullet under "Navigation and
  library".

Full Recipe and Focus Mode are unchanged. Their amounts follow a count chosen
before cooking and do not change on screen.

## Verification

- `git diff --check`: clean.
- `xcodebuild build -scheme Ladle -configuration Debug` for an iOS 27
  simulator: succeeds, with the Share Extension and LadleTimers embedded. It
  adds no warnings; the only Swift warning is the existing unused `viewport` in
  `WatchView.swift`.
- `xcodebuild test -scheme LadleAllTests -only-testing:LadleTests`: passes.
  `RecipeScalingTests` and `IngredientRowTextTests` pass unchanged.
- `LadleCore` did not change, so `swift test --package-path
  Packages/LadleCore` was not needed.

### Captures

Captures are added at integration. They should cover: stepping up and down on
the Smash Burgers fixture (the one with a "Not scaled" row), Reset from a
scaled count, 9 to 10 servings, where the count widens, and the same steps
under Reduce Motion.
