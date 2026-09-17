# Focus Mode: amounts under "For this step"

Date: September 17, 2026
Issue: [#160](https://github.com/chetangoel01/overeasy/issues/160)
Branch: `codex/feedback-focus-and-icon-picker`
Status: **built, unit-tested and captured on a simulator created for the task.**

## Purpose

A TestFlight tester asked for "the amount of each thing (ex. 1 pepper,
1 tbsp)" under **For this step**, so a step can be cooked without going back
to the ingredient list. Focus Mode printed only the names, in one line.

## What the cook sees

- **For this step** is a short list, one row per ingredient linked to the
  current step: the amount, semibold, in a fixed leading column, and the name
  beside it with its preparation, as Full Recipe writes it.
- Amounts follow the serving count chosen before cooking and come from the
  same formatter as Full Recipe: two fraction digits, a bare number for a
  count, never a unit without a number. An ingredient with no quantity — salt
  to taste — is its name alone; nothing is invented for it.
- An ingredient that other steps also use shows its whole-recipe amount and
  says so under the name: "Recipe total. Also used in step 4.", or "steps 2
  and 3". The app never splits an amount between steps.
- The header is a small disclosure: secondary text and a chevron on a
  44-point target. Expanded is the default. Folded, the section is the single
  line of names it used to be. It stays how the cook left it from step to
  step and through Full Recipe and back, until cooking ends; it is not stored.
- VoiceOver reads the header as a button whose value is "Expanded" or
  "Collapsed", and each row as one element: "2 lb, boneless skin-on chicken
  thighs, Recipe total. Also used in steps 2 and 3."
- Reduce Motion folds and unfolds without animation.
- At accessibility sizes the amount sits above the name instead of beside it.
  A long list scrolls beneath the pinned step controls, so **Next step** stays
  reachable.

## Decisions

The owner approved, on September 17: amounts under "For this step" in the
two-column form of the mock; whole-recipe totals labelled when an ingredient
is reused rather than any per-step split; and, after the mock, a very small
toggle to fold the details away, expanded by default and kept for the session.

Engineering calls, each open to a veto:

1. **The name carries its preparation** ("garlic — grated"), in Full
   Recipe's own form. The mock's "garlic, smashed" reads as name and
   preparation, and one formatter serves both screens. The folded line stays
   names only, as it was.
2. **The "Recipe total" line appears only beside an amount.** Flaky salt used
   in two steps has no figure a cook could mistake for this step's share.
3. **No "Not scaled" marker in Focus Mode.** Full Recipe keeps it; here a row
   with no amount already reads as its name.
4. **The amount column is 96 points, scaled with the text.** It fits
   "1.25 cups" at the default size, keeps the names on one edge from step to
   step, and lets a longer amount wrap inside the column rather than push one
   row out of line. A grid sized to each step's widest amount was the
   alternative; it moves the names between steps.
5. **Rows are 20 points through `ladleScaledFont`**, relative to `title3`, in
   semibold and regular. `recipeTitle` is that size in semibold only, so a
   role would have covered half a row. DESIGN.md's sentence on
   `ladleScaledFont` now says what it is used for: the timer clock was
   already a cooking surface below `display`.
6. **The chevron is swapped, not rotated.** A turned `chevron.right`
   overflows its own narrow frame and crowded the label.
7. **The 44-point target is drawn back into the spacing around it** at
   ordinary sizes, so the label sits where a caption would. At accessibility
   sizes the label fills the target and keeps its room.
8. **No haptic on the fold**, in line with the feedback policy: it is neither
   a selection nor a completion.

## Affected components

- `Ladle/Design/RecipePresentation.swift`: `amountText(scaledBy:)` is now the
  one place an amount is decided; `amountText`, `cookingDetailText` and
  `cookingDetailText(scaledBy:)` go through it. `nameText` is the row without
  its amount.
- `Ladle/Cooking/CookingViewModel.swift`: `StepIngredient` and
  `stepIngredients` replace `relevantIngredients`, adding the scaled amount
  and the other steps that share the ingredient, numbered from 1.
  `showsStepIngredientAmounts` is the fold, held for the session.
- `Ladle/Cooking/FocusModeView.swift`: the disclosure header, the rows, the
  folded line and the accessibility-size layout.
- `DESIGN.md`: the Cooking rules and the `ladleScaledFont` sentence.

## Verification

Red first, against a view model that still printed the recipe's own amounts
and knew nothing of other steps:

```
CookingViewModelTests.swift:80: … XCTAssertEqual failed: ("[Optional("2 lb"), Optional("1 bunch")]") is not equal to ("[Optional("4 lb"), Optional("2 bunch")]")
CookingViewModelTests.swift:84: … XCTAssertEqual failed: ("[[], []]") is not equal to ("[[1, 3], []]")
```

- One new test, `testStepIngredientsCarryScaledAmountsAndTheOtherStepsSharingThem`:
  a doubled gochujang chicken at step 2, where the thighs are shared with
  steps 1 and 3 and the scallions with none. The fold is asserted inside the
  existing mode-switching test rather than in a test of its own, and the
  existing current-step test reads the new property. Wording is not tested.
- The row formatter is already covered by `IngredientRowTextTests`, which now
  runs through `amountText(scaledBy:)`: 35 focused tests pass.
- Full app suite on iPhone 17 Pro, iOS 26.5: `Executed 591 tests, with 1 test
  skipped and 0 failures`. The skip is the live App Attest test, as before.
- `swift test --package-path Packages/LadleCore` was not run: the package is
  untouched.

## Captures

iPhone 17 Pro simulator, iOS 26.5, created for the task and deleted after it.
Focus Mode keeps its graphite ground in both appearances, so light and dark
differ only in that ground. All from the demo library; no fixture was added.

| | Before | After |
| --- | --- | --- |
| Dark | [names only](captures/2026-09-17-focus-step-amounts/before-dark.png) | [amounts, feta shared with step 4](captures/2026-09-17-focus-step-amounts/after-dark-expanded-reused.png) · [folded](captures/2026-09-17-focus-step-amounts/after-dark-collapsed.png) |
| Light | [names only](captures/2026-09-17-focus-step-amounts/before-light.png) | [amounts](captures/2026-09-17-focus-step-amounts/after-light-expanded-reused.png) · [folded](captures/2026-09-17-focus-step-amounts/after-light-collapsed.png) |
| Largest text | [one wrapped line](captures/2026-09-17-focus-step-amounts/before-dark-ax5.png) | [header and first row](captures/2026-09-17-focus-step-amounts/after-dark-ax5-header.png) · [amount above name](captures/2026-09-17-focus-step-amounts/after-dark-ax5-rows.png) · [light](captures/2026-09-17-focus-step-amounts/after-light-ax5-rows.png) · [folded](captures/2026-09-17-focus-step-amounts/after-dark-ax5-collapsed.png) |

- [A timer, a shared row and a row with no amount](captures/2026-09-17-focus-step-amounts/after-dark-timer-and-no-amount.png):
  smash burgers, step 2. Kosher salt is its name alone.
- [Seven ingredients](captures/2026-09-17-focus-step-amounts/after-dark-long-list.png),
  and [the same list scrolled](captures/2026-09-17-focus-step-amounts/after-dark-long-list-scrolled.png)
  with Next step still in place: gochujang chicken, step 1, "steps 2 and 3".
- [Still folded on the next step, after a trip through Full Recipe](captures/2026-09-17-focus-step-amounts/after-dark-collapsed-after-full-recipe.png).
