# Design Language Migration Implementation Plan

> **For Codex:** Use the executing-plans and test-driven-development skills to
> implement this plan task by task.

**Goal:** Move Overeasy onto semantic colour, spacing, and button roles while
fixing the visual defects those roles expose.

**Architecture:** `LadleTheme`, `LadleTypography`, and `LadleComponents` own the
shared vocabulary. Screens state intent through those roles and keep any
screen-specific composition local. `LadleShare` mirrors tokens it cannot import
from the app target.

**Tech stack:** Swift 6, SwiftUI, XCTest, XCUITest, and iOS 26.5 simulators.

---

Companion to the semantic design roles added in `LadleTheme`,
`LadleTypography` and `LadleComponents`. The roles are defined and the app
builds on them; this records what still has to move onto them, and why each
group matters.

## Why this exists

The palette and the 4/8/12/16/24/32 spacing scale already existed. What did
not exist was anything saying *which* step or token belonged *where*, so the
app grew a second, undeclared spacing scale beside the real one and four alias
pairs beside the real palette.

Measured on `codex/notifications-preferences-discover-grid` at `f2ceb74`:

- 254 hardcoded `padding` / `spacing` literals against 112 uses of
  `LadleTheme.Spacing` — raw numbers outnumber tokens 2.3 to 1.
- 138 of those 254 (54%) are not steps on the scale.
- 141 `Button` declarations, 62 of which use a Ladle button style.
- 42 ad-hoc `.font(.system(size:))` calls across 16 distinct sizes.
- Six distinct control heights: 44, 46, 48, 50, 52, 56.

## Spacing: the shadow scale

`10` and `14` together accounted for 64 uses. They were not typos; they were a
second scale that grew because nothing named the first one's roles.

**Done.** The app is at **1 off-scale literal, from 83.** Every file is on the
scale except one deliberate exception, described below. The original count of
138 was measured with a looser pattern than the one used since; the comparable
starting figure is 83, and even that missed a literal hidden inside a ternary
in `RecipeMetadataBand`.

Control heights fold into three: 46 and 48 to `Control.field`; 50, 52 and 56 to
`Control.primary`; 44 stays `Control.hitTarget`. **Not started** — a settings
row moving from 56 to 48 is a visible change rather than a rounding, so it
wants its own pass with screenshots.

### The rules the first six files settled

Where the table offers two neighbours, these broke the tie, and the rest of the
migration should follow them so the app does not grow a third scale:

- **Text to text** — a title and the line supporting it — rounds to `tight`.
- **Label to control** — a field label above its field — rounds to `compact`.
- **A row's inner padding** goes to `cardPadding` horizontally and `medium`
  vertically. Matching `cardPadding` on both axes would grow every row by 12.
- **Icon to label** is `iconGap`, and a divider separating such rows derives
  its inset with `dividerInset` rather than restating the sum.
- **A sibling in the same file wins over the table.** ReimportSheet's Original
  source card takes `tight` to match RecipeEditorView's copy of the same card;
  AddRecipeSheet's lone `10` label gap takes `compact` because its two
  neighbours already used 8.
- **Round in the direction that keeps behaviour.** RecipeEditorView's quantity
  and unit fields sit in a `ViewThatFits`, so their gap rounds down; widening
  it would push more cases into the stacked fallback.

### Scroll clearance: two roles, not one

Measured rather than guessed, as this document asked. At full scroll the
Recipes list already clears the floating tab bar by about 45 points, because
the system insets a tab screen's scroll view on its own. So the 30 to 48 those
six screens carried was never bar clearance — it was breathing room on top of
it, and they now share `Layout.scrollTail`.

Watch is the exception and the reason a single role would have been wrong. Its
content runs full-bleed under the bar, the system insets nothing, and the
`88 + medium` it added by hand is real clearance. That is
`Layout.overlayBarClearance`, and it is the one layout value allowed off the
spacing scale, because it is the height of a bar rather than a chosen distance.

`WatchView:66` still pads its overlay control down by a literal 60 for the same
reason at the top of the screen. It is the one off-scale literal left in the
app. Both it and `overlayBarClearance` would be better read from the safe-area
insets than stated as constants; that is a different change from this one.

### A second design system

`LadleShare` is its own target and cannot see `LadleTheme`, so
`ShareConfirmationView` hand-mirrors the palette in a private `ShareTheme`. The
spacing scale is now mirrored there too, which is consistent but doubles what
can drift — and it already has: `ShareTheme` still defines `field` and `review`,
two alias names the app deleted. Sharing the tokens through `LadleCore` is the
real fix.

## Colour

Replace the alias pairs, then the palette names, with semantic roles. No colour
values change; `Surface.badge` is the only new value.

The four alias pairs are done, one commit each. Every alias bound the very same
`Color` its role names, so the swap is value-preserving by construction, and the
Recipes screen is pixel-identical before and after. Each commit also deleted its
alias definition, which makes the compiler prove the migration is total rather
than leaving a name for a later grep to miss.

| Replace | With | Uses | Status |
| --- | --- | --- | --- |
| ~~`paprika`~~ | `Label.accent` | 51 | done, `68f8324` |
| ~~`field`~~ | `Surface.raised` | 28 | done, `378a6c5` |
| ~~`review`~~ | `Surface.steel` | 28 | done, `2630682` |
| ~~`success`~~ | `Intent.success` | 10 | done, `41a62a3` |
| ~~`ink`~~ | `Label.primary` | 176 | done in consolidation Task 11 |
| ~~`onAccent`~~ | `Label.onAccent` | 51 | done in consolidation Task 11 |
| ~~`paper`~~ | `Surface.porcelain` | 45 | done in consolidation Task 11 |
| ~~`mutedInk`~~ | `Label.secondary` | 30 | done in consolidation Task 11 |

The remaining four are palette names rather than aliases, so they cannot be
deleted from `LadleTheme` — the roles are defined in terms of them. Production
screens no longer call them directly.

`butter`, its light/dark constants, and its duplicate catalog entry were
removed together in consolidation Task 11.

### Left behind by the mechanical pass

Both groups below change pixels, which is why they stayed out of the alias
commits.

Nine `Label.accent` sites tint or fill rather than colour a foreground.
`Intent.accent` is a different value — `brick`, not `accentText` — so each site
needs deciding on its own. `FullRecipeView:100`, `PendingImportCard:72`,
`ReimportSheet:143`, `RecipeEditorView:313` and `:358`, and `AddRecipeSheet:288`
tint controls. `PrivacyDetailView:76`, `IngredientList:21` and
`RecipeDetailView:330` fill bullets — and a bullet is decoration, which `Intent`
explicitly excludes, so those three may want no accent at all.

Thirteen sites draw a circular icon badge in `Surface.steel`. On a `raised` card
steel sits about four percent off the card behind it, which is the
invisible-badge finding; those move to `Surface.badge`. Badges on the porcelain
ground may stay. `AccountSheet:58`, `:126`, `:384`, `:429`;
`AddRecipeSheet:290`, `:373`, `:431`, `:504`; `ReimportSheet:236`, `:356`;
`HealthExportSheet:90`; `GuestLimitView:17`; `FailedImportSheet:81`.

## Buttons

Move the 79 `Button` declarations that bypass the Ladle styles onto
`LadleButtonStyle`. Two behaviours only the roles can fix:

- Delete actions become `.destructive`. In the recipe options sheet, delete is
  currently indistinguishable from four benign actions.
- Icon-and-label buttons stop centring the pair as one group. The failed-import
  recovery stack currently gives its three buttons three different label
  origins, spanning 19pt.

## Known layout defects this unblocks

Fixed:

- ~~Recipe grid capped at 146~~ — fixed in `8c85e20`. The cap sat in two
  places, `AllRecipesView`'s `GridItem` columns *and* `RecipeGridCard`'s own
  frame; removing only the first leaves the card centred in its cell.
- ~~Sign in with Apple black on graphite~~ — fixed in `0c12ea7`.
- ~~Cooking checklist dividers hardcoded to 52 against labels at 43~~ — fixed
  in `2f6df35`. Both now derive from one named icon width, measured on device
  at the same pixel.
- ~~Privacy detail dividers hardcoded to 22 against labels at 18~~ — fixed in
  `3b6d3bf`. The same defect four points wide. Measured on device: the divider
  moved from x=138 to x=126, where the labels are.

Four row-and-divider pairs were audited in total. Two were adrift — the cooking
checklist by 9 points and the privacy list by 4. Two were already correct,
`AllRecipesView`'s collections and `IngredientList`, and both now derive their
inset anyway: IngredientList would otherwise have *become* misaligned when its
icon gap moved onto `iconGap`, which is the argument for deriving rather than
rounding.

Outstanding, each with a role that now exists to express the fix:

- Sheet close controls sit on 16 while sheet bodies sit on 24, across seven
  screens. Focus Mode is the only one already correct — use
  `Layout.sheetMargin` for both.
- The failed-import recovery stack centres each button's icon and label as one
  group, giving three buttons three label origins across a 19pt spread.
- Recipe options styles delete identically to four benign actions — use
  `LadleButtonRole.destructive`.

## Sequencing

1. ~~Colour aliases~~ — done. The four alias pairs are gone.
2. ~~Off-scale spacing~~ — done. 83 literals to 1.
3. Button roles, which carries the two behaviour fixes above.
4. The layout defects, which are call-site changes rather than token changes.

Steps 1 and 2 should be visually identical where they only round to a
neighbouring step; capture Recipes, a sheet, and Focus Mode before and after
each file to confirm.

## Step 3, batch 1: semantic actions

This batch makes the first production uses of `LadleButtonRole` and fixes the
two button defects identified by the audit. The saved `b2/after/10-options.png`
capture is the recipe-options before-state from `51dbe8f`; capture the failed
import state during the red UI test so its three label origins are measured on
the same build.

### Task 1: prove the two defects

**Complete.** The unit test failed first on the absent semantic role and inset
APIs. Once the visible recovery text was independently addressable, the UI test
measured x-origins of 137.3, 142.2, and 154.5 points: a 17.2-point spread on the
iPhone 17 simulator.

**Files:**

- Modify `LadleTests/DesignTokenTests.swift`.
- Modify `LadleUITests/DiscoverInteractionUITests.swift`.

1. Add a unit test requiring `.delete` to resolve to `.destructive`, benign
   recipe options to resolve to `.tertiary`, and a full-width tertiary style to
   add no implicit horizontal inset.
2. Run only that unit test. It must fail because `RecipeOption.buttonRole` and
   `LadleButtonStyle.horizontalPadding` do not exist yet.
3. Add a UI test that drives the demo importer with a `parser-failed` URL and
   compares the `minX` values of “Add correction notes”, “Paste recipe details”,
   and “Create manually”.
4. Run only that UI test. It must fail on the existing centred labels; save a
   simulator screenshot under `~/Desktop/overeasy-ui-scratch/step3/before/`.

### Task 2: distinguish the destructive recipe option

**Implemented.** Benign rows remain full-width tertiary actions with their
existing visual hierarchy. Delete alone receives the destructive fill and
on-destructive foregrounds. A full-width tertiary row now owns its content
inset, while the default hugging tertiary action keeps its 16-point hit-area
padding.

**Verification:** The focused semantic-role test and the complete
`DesignTokenTests` target pass on the iPhone 17 iOS 26.5 simulator. The unit
test was observed failing first on the missing `buttonRole` and
`horizontalPadding` APIs.

**Files:**

- Modify `Ladle/Design/LadleComponents.swift`.
- Modify `Ladle/RecipeDetail/RecipeOptionsSheet.swift`.
- Test `LadleTests/DesignTokenTests.swift`.

1. Make full-width tertiary rows opt out of the hugging tertiary inset while
   preserving the inset for the default hugging form.
2. Give `RecipeOption` a semantic role: `.delete` is `.destructive`; every
   other option is `.tertiary`.
3. Apply `LadleButtonStyle(role:isFullWidth:)` to every option. Keep benign rows
   otherwise unchanged and let the destructive role provide the delete fill;
   its rich row content must use destructive-safe foregrounds.
4. Run the focused unit test, then `DesignTokenTests`; both must pass.
5. Run `git diff --check`, update this document with the verification result,
   and commit the coherent change.

### Task 3: align failed-import recovery labels

**Implemented.** Retry now states `.primary` directly. The three recovery
actions state `.secondary` and share a 28-point icon column, 12-point icon gap,
and 16-point content inset, so label position no longer depends on title width.

**Verification:** The alignment UI test and recipe-options screenshot test both
pass. Before/after captures live under
`~/Desktop/overeasy-ui-scratch/step3/{before,after}/` on the MacBook Pro. The
complete `LadleTests` run contains 195 tests: 194 passed, 1 skipped, 0 failed.

**Files:**

- Modify `Ladle/Import/ImportRecoveryActions.swift`.
- Test `LadleUITests/DiscoverInteractionUITests.swift`.

1. Replace the legacy primary wrapper with
   `LadleButtonStyle(role: .primary)`.
2. Build each recovery action from a leading `HStack` with one shared icon
   column, `Layout.iconGap`, and one horizontal content inset. Apply
   `LadleButtonStyle(role: .secondary)` and remove the hand-built background,
   height, font, and foreground modifiers the role now owns.
3. Re-run the alignment UI test. All three text origins must match within one
   point; save the after screenshot beside the before-state.
4. Run the focused unit and UI tests, then all `LadleTests`.
5. Run `git diff --check`, record verification here, and commit the coherent
   change.

### Batch 1 checkpoint

- `acbf7d3` makes the recipe-options rows semantic and visually distinguishes
  Delete without changing the four benign rows.
- `1b75087` moves the failed-import stack onto primary/secondary roles and one
  shared leading label edge.
- Nine button declarations are covered by the two reusable call sites in this
  batch. Recount the remaining bypasses before planning batch 2 because the
  baseline inventory predates three Watch commits.
- MacBook Pro verification at `1b75087`: 195 `LadleTests` total, 194 passed,
  1 skipped, 0 failed; both focused UI tests passed; the full Ladle build
  succeeded and contains `Ladle.app/PlugIns/LadleShare.appex`.
- The MacBook-generated evidence is
  `~/Desktop/overeasy-ui-scratch/step3/after/{failed-import,options}-macbook.png`;
  the matching before captures sit in the sibling `before` directory.

## Step 3, batch 2: explicit roles and complete control inventory

The consolidation recount on August 26, 2026 found 126 declarations across
the app and Share Extension: 125 SwiftUI `Button` declarations plus the native
Sign in with Apple control. Each declaration is classified below. `S` is a
semantic action, `N` is an action owned by a native menu/dialog/context menu,
`I` is navigation or an icon-only control, and `R` is a row/card/chip
interaction. The counts describe declarations, not runtime instances produced
by `ForEach`.

| Source | S | N | I | R | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| `LadleShare/ShareConfirmationView.swift` | 1 | 0 | 0 | 0 | 1 |
| `Ladle/RecipeDetail/RecipeDetailView.swift` | 5 | 2 | 3 | 0 | 10 |
| `Ladle/Edit/ReimportSheet.swift` | 4 | 0 | 1 | 0 | 5 |
| `Ladle/RecipeDetail/RecipeOptionsSheet.swift` | 1 | 0 | 1 | 0 | 2 |
| `Ladle/RecipeDetail/RecipeMetadataBand.swift` | 0 | 0 | 0 | 1 | 1 |
| `Ladle/Cooking/FocusModeView.swift` | 1 | 0 | 2 | 1 | 4 |
| `Ladle/Edit/RecipeEditorView.swift` | 2 | 0 | 6 | 1 | 9 |
| `Ladle/Design/LadleComponents.swift` | 2 | 0 | 1 | 0 | 3 |
| `Ladle/Cooking/FullRecipeView.swift` | 1 | 1 | 1 | 2 | 5 |
| `Ladle/Cooking/RecipeTimer.swift` | 0 | 0 | 2 | 0 | 2 |
| `Ladle/App/AppBootstrap.swift` | 1 | 0 | 0 | 0 | 1 |
| `Ladle/Library/RecipeGridCard.swift` | 0 | 0 | 1 | 0 | 1 |
| `Ladle/Library/FilterSheet.swift` | 1 | 0 | 2 | 1 | 4 |
| `Ladle/Library/VideoEmbedSheet.swift` | 0 | 0 | 1 | 0 | 1 |
| `Ladle/Library/RecipeListRow.swift` | 0 | 0 | 1 | 0 | 1 |
| `Ladle/Library/RecipeContextMenu.swift` | 0 | 2 | 0 | 0 | 2 |
| `Ladle/Library/WatchView.swift` | 7 | 2 | 0 | 0 | 9 |
| `Ladle/Library/AllRecipesView.swift` | 0 | 4 | 2 | 2 | 8 |
| `Ladle/Library/ImportInboxView.swift` | 0 | 4 | 0 | 1 | 5 |
| `Ladle/Library/DiscoverView.swift` | 3 | 2 | 0 | 2 | 7 |
| `Ladle/Health/HealthExportSheet.swift` | 3 | 0 | 1 | 0 | 4 |
| `Ladle/Account/GuestLimitView.swift` | 2 | 0 | 0 | 0 | 2 |
| `Ladle/Library/LibraryView.swift` | 2 | 1 | 2 | 0 | 5 |
| `Ladle/Import/FailedImportSheet.swift` | 0 | 0 | 1 | 0 | 1 |
| `Ladle/Nutrition/NutritionView.swift` | 1 | 0 | 1 | 0 | 2 |
| `Ladle/Account/OnboardingWalkthroughView.swift` | 1 | 0 | 1 | 0 | 2 |
| `Ladle/Account/AccountSheet.swift` | 0 | 5 | 1 | 3 | 9 |
| `Ladle/Import/AddRecipeSheet.swift` | 10 | 2 | 1 | 0 | 13 |
| `Ladle/Account/WelcomeView.swift` | 3 | 0 | 0 | 0 | 3 |
| `Ladle/Import/ImportRecoveryActions.swift` | 2 | 0 | 0 | 0 | 2 |
| `Ladle/Import/CorrectionNotesView.swift` | 1 | 0 | 1 | 0 | 2 |
| **Total** | **54** | **25** | **33** | **14** | **126** |

The first migration in this batch is value-preserving. Thirty-two call sites
now state `.primary` or `.secondary` directly through `LadleButtonStyle`; the
compatibility `LadlePrimaryButtonStyle` type is deleted. Native menu/dialog
actions, icon controls, and row/card interactions retain their native or press
styles. Later Task 11 batches will review the remaining hand-built semantic
actions individually, because Focus Mode, Sign in with Apple, and compact
inline recovery actions have intentional presentations that should not be
mechanically flattened into the filled-button shape.

Verification on August 26, 2026:

- the structural test failed first with all source files retaining the legacy
  wrapper, proving the red state;
- zero production references remain and the structural test passes;
- all 19 `DesignTokenTests` and the two focused recovery/options UI tests pass;
- the complete `LadleTests` target passes 228 tests: 227 passed and the one
  live App Attest test was intentionally skipped;
- the UI tests retained 1,206 by 2,622 pixel screenshots at
  `~/Desktop/overeasy-ui-scratch/consolidated-step11/button-wrapper-20260826-1425/`;
  visual review confirms the recovery labels and destructive option remain
  unchanged.

## Step 4, batch 1: semantic color consumers and asset cleanup

Every app screen now consumes `Surface`, `Label`, `Intent`, or `Stroke`; raw
palette names remain only inside `LadleTheme`, where the semantic roles are
defined. The migration covers porcelain/raised/steel/graphite surfaces,
primary/secondary/on-accent/fixed/accent labels, and accent/success/focus
intent. It is value-preserving: each new expression resolves through the same
theme value the call site previously addressed directly.

The Share Extension cannot import the app target, so its local mirror now uses
the same `Surface`, `Label`, and `Intent` namespaces instead of the stale
`field` and `review` aliases. Structural tests protect both targets. The
duplicate `Butter` asset and the retired `Field`, `Paprika`, `Review`, and
`Success` compatibility assets are deleted; `AccentColor` remains because
Xcode consumes that catalog name even though Swift source does not.

Verification on August 26, 2026:

- three structural tests first failed on raw palette consumers, Share aliases,
  and all five catalog directories, proving the red state;
- the same tests pass with raw app palette calls confined to
  `Ladle/Design/LadleTheme.swift` and no retired asset directories present;
- 22 `DesignTokenTests`, 7 rendered Share tests, and 3 focused UI tests pass;
- the complete `LadleTests` target passes 231 tests: 230 passed and the one
  live App Attest test was intentionally skipped;
- a generic simulator build passes for the Ladle app and its embedded Share
  Extension; the remaining Google Sign-In sendability warning is tracked for
  the repository completion pass;
- nine retained captures cover Recipes grid/list, Settings, Watch, recipe
  options, and Share loading/success/failure including dark and accessibility
  appearances at
  `~/Desktop/overeasy-ui-scratch/consolidated-step11/semantic-colors-20260826-1437/`;
  visual review found no unintended color or contrast drift.
