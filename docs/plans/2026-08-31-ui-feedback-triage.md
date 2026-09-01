# UI feedback triage — Discover, Settings, Inbox, accent

Date: August 31, 2026
Status: **validated, nothing implemented.** More notes are expected; this
document is the running list.

## Purpose

Chetan gave a spoken list of eleven observations after using the app against
the live backend. This records each one in his words, says whether it holds up,
gives the evidence, and proposes a direction. Two items need a product decision
before any code is written; the rest are ordinary defects or small additions.

Nothing here has been built. `main` is on the TestFlight build (`6d5806a`) and
should stay clean until this list is agreed.

## Summary

| # | Item | Verdict |
|---|------|---------|
| 1 | Land on Discover by default | Confirmed — one-line default, has test surface |
| 2 | Alternate Discover shapes at 1,000 recipes; featured | **Needs decision** — options below |
| 3 | Watch view is good | No action requested |
| 4 | Deprioritize Instagram in Discover | **Withdrawn by the user** |
| 5 | Plus icon in Inbox; import from the empty state | Confirmed — neither exists |
| 6 | Does the accent apply app-wide? | **No.** Root `.tint` is reactive; 76 other reads are not |
| 7 | Settings sections off-HIG; Close button padding | Confirmed, both parts, measured |
| 8 | Settings/profile work for a paid tier | **Needs decision** — real scaffolding exists |
| 9 | Sort menu looks jarring | Confirmed — the **Recipes** menu, not Discover's |
| 10 | Accent doesn't update the screen behind the sheet | Confirmed — same root cause as #6 |
| 11 | Pull-to-refresh should show new recipes | Partly — refresh works, ranking is deterministic |

Items 6 and 10 are one bug. Items 7 and 9 are the same class of problem as the
filter sheet that was already rewritten: hand-rolled chrome where a system
control belongs.

---

## 1. Land on Discover by default

> "I think we should land the user at the Discover page by default."

**Confirmed as a change, not a defect.** The app opens on Recipes today:
`LibraryNavigationState.tab` defaults to `.recipes`
([LibraryView.swift:21](../../Ladle/Library/LibraryView.swift:21)), confirmed on
device — a cold launch shows the Recipes tab selected.

Two things move with it:

- `testLibraryStartsOnRecipesTab`
  ([LibraryNavigationStateTests.swift:7](../../LadleTests/LibraryNavigationStateTests.swift:7))
  asserts the current default directly.
- `reviewDidComplete(hasActionableImports:)`
  ([LibraryView.swift:55](../../Ladle/Library/LibraryView.swift:55)) falls back
  to `.recipes` after a review finishes. That is a *different* decision — after
  reviewing an import you belong with your own library, not in Discover — and
  should probably stay as it is.

One consideration worth raising before doing it: a returning cook opening to a
feed of other people's recipes rather than their own library is a real product
stance, not just a default. It also puts a network request on the launch path,
so a cold launch with no signal lands on an error or empty state instead of the
saved library. Worth deciding whether Discover-first applies always, or only
when the library is empty.

**Effort:** small.

---

## 2. Discover at 1,000 recipes, and "featured"

> "I want to explore a couple more implementations of the Discover page because
> when we scale to 1,000 recipes, I think we might have to check out an
> alternate way of doing that. Maybe we have featured recipes too. I don't
> know."

**Needs a decision — no direction picked here.** The reachability problem you
flagged before is already fixed: Discover pages with an integer cursor, 30 per
page, prefetching 8 rows from the end, and search and sort both run on the
server ([DiscoverService.swift](../../Ladle/Remote/DiscoverService.swift),
[repository.py:102](../../Backend/ladle/recipes/repository.py:102)). So 1,000
recipes are all *reachable*. What is missing at that size is a reason to look
past the first page.

Today the feed is one flat ranked list with three orderings — Most saved, Most
liked, A to Z — under one static heading, "Saved by cooks".

Options, in rough order of cost:

1. **Sections instead of one list.** "New this week", "Most saved", "Quick
   dinners" as horizontal shelves with a flat list underneath. The backend
   already stores `published_at` (unexposed, and absent for Instagram) and
   total time, so two of those shelves are query changes, not new data.
2. **Featured.** A curated or editorially-flagged set pinned to the top. Needs a
   new column and some way to set it — there is no admin surface today, so in
   practice that means a SQL update or a small script until one exists.
3. **Tags or cuisine facets.** The most useful at 1,000 items and the most
   expensive: nothing classifies recipes today, so it needs either a
   classification pass over the corpus or new extraction output.
4. **Personalization.** Rank against what the cook has already saved. Most
   valuable, most work, and it needs enough per-user history to be worth it.

My read: (1) is the highest ratio of value to cost and does not foreclose any of
the others. But this is your call to make, not mine.

**Effort:** small (1) to large (3, 4).

---

## 3. Watch view

> "The watch view is pretty good now, honestly."

No action requested. Noted so the list stays complete.

---

## 4. Deprioritizing Instagram in Discover

> "Maybe we deprioritize Instagram in Discover, but never mind. That sounds too
> complicated."

**Withdrawn by you in the same breath.** Recorded so it does not get
re-discovered later as an open idea. For what it is worth it would not be
especially complicated — a source weight in the ranking — but there is no reason
to do it unless Instagram results actually turn out worse.

---

## 5. A plus in the Inbox, and importing from its empty state

> "Can we add a plus icon in the inbox? Maybe if we say there are no imports,
> then we should be able to add imports from the inbox screen. It's intuitive,
> and it just makes sense."

**Confirmed, both halves.**

- The add button is built only into the Recipes tab. `recipesTab` puts
  `accountButton` and `addRecipeButton` in the toolbar; `inboxTab` puts only
  `accountButton` ([LibraryView.swift:295, 389](../../Ladle/Library/LibraryView.swift:295)).
  `LibraryTab.toolbarActions` states the same rule and is covered by a test.
- The empty state is a `ContentUnavailableView` with a title and description and
  **no action** ([ImportInboxView.swift:51](../../Ladle/Library/ImportInboxView.swift:51)) —
  a dead end, verified on device (capture 07).

You are right that this is the intuitive behaviour, and it is cheap:
`ContentUnavailableView` takes an `actions:` closure, and `isAddSheetPresented`
is already owned by `LibraryView`, so both halves reuse the existing sheet.

**Effort:** small.

---

## 6 & 10. The accent colour does not reach the whole app

> "Changing the accent in the settings, can you confirm it works for the whole
> app?"
>
> "Changing the accent doesn't always change the current screen behind the
> full-screen sheet. It requires me to click in and out."

**It does not work for the whole app, and these are one bug.** Answering the
first question directly: no. The reactive part is only the root tint.

**Root cause.** `LadleTheme.Intent.accent`, `Label.accent` and `brick` are
computed properties that read `UserDefaults` at body-evaluation time
([LadleTheme.swift:203](../../Ladle/Design/LadleTheme.swift:203)). SwiftUI has no
dependency on `UserDefaults`, so changing the accent invalidates nothing. A view
picks up the new colour only when it re-renders for some unrelated reason —
which is exactly what "click in and out" does.

There are **76 such reads across 28 files.** The worst-placed one is
`LibraryView`'s own `.tint(LadleTheme.Intent.accent)`
([LibraryView.swift:112](../../Ladle/Library/LibraryView.swift:112)): it is a
static read that *overrides* the correctly reactive `.tint` the app root applies
from `@AppStorage` ([LadleApp.swift:108](../../Ladle/App/LadleApp.swift:108)).
So the one part of the system that was wired properly is shadowed by a stale
value for the whole library.

**Reproduced on device, in both directions:**

- Opened Settings over Discover, chose Blue. The sheet itself turned blue
  immediately — it reads the value through `@AppStorage`, so its own body
  re-runs. Closed it: Discover was **entirely unchanged**, still Tomato — Save
  buttons, creator handles, toolbar icons, tab bar. *Observed live; this first
  pass was not written to a file.*
- Switched to Recipes and back: both tabs were now blue. The tab switch forces
  the re-render.
- Repeated it in the other direction, and captured this one: **capture 05** is
  Discover in Blue, then Settings was opened over it and Sage chosen; **capture
  06** is Discover immediately after closing the sheet, still Blue.
  Deterministic, not a timing flake.

**Why this was never caught.** The one UI test that touches the accent
(`testSettingsAccentAndRecipeViewPreferencesAreReachable`,
[DiscoverInteractionUITests.swift:96](../../LadleUITests/DiscoverInteractionUITests.swift:96))
taps Blue and asserts the *swatch* reports "Selected". It never asserts the
accent reached anything. The
[2026-08-25 doc](../verification/2026-08-25-settings-discover-and-library-layout.md)
claims the accent "updates primary actions, active navigation, favorites, and
attention indicators" — that was the intent, and it was never verified.

**Direction.** Make the accent an observed value rather than a global function
call: publish it into the environment from the root (which already observes
`@AppStorage`) and have `LadleTheme`'s accent roles resolve from the
environment. That is a mechanical change across 28 files, but it fixes every
site at once and makes the failure impossible to reintroduce, because a static
read would no longer compile. Whatever the shape, it wants a UI test that
asserts the accent *outside* the sheet after a change.

**Effort:** medium — the fix is mechanical but wide.

---

## 7. The Settings screen

> "Can you do a UI check on the settings screen? I don't think the different
> sections are very much in line with iOS design guidelines. It also looks like
> the close button on the top left has weird padding, and it's not centered in
> the button."

**Both parts confirmed.** Captures 03 and 04.

### The sections

The screen is a `ScrollView` of hand-built cards
([AccountSheet.swift:65–99](../../Ladle/Account/AccountSheet.swift:65)) — custom
`LadleSectionHeader`s, custom rows, hand-drawn dividers with a derived inset,
and circular icon badges. It is not a `Form` or a `List`. Concretely, against
the platform:

- Section headers render as large bold primary-colour text; a grouped list uses
  small secondary-colour headers.
- Rows are `minHeight: 64` and `Control.primary` (52); system rows are 44.
- "Accent color" hangs off the right of the "Appearance" header as a detail —
  there is no such affordance in iOS settings; it would be a footer.
- Chevrons, dividers and row backgrounds are all re-implemented.

This is the same failure the filter sheet had, and it has the same fix: a
grouped `Form`, as `FilterSheet` now is
([FilterSheet.swift](../../Ladle/Library/FilterSheet.swift)). Rewriting it that
way would delete most of the 536 lines.

### The Close button

Measured from a 3× capture: the glass capsule is **8 points wider than the label
needs**, and the label sits **4 points right of the capsule's centre** — which
is precisely half of the 8-point padding, i.e. all of the padding lands on one
side.

The cause is `.padding(.leading, LadleTheme.Layout.sheetToolbarInset)` applied to
the button *inside* the toolbar item
([AccountSheet.swift:89](../../Ladle/Account/AccountSheet.swift:89)). That inset
was introduced to move a toolbar control from the system's 16-point edge onto
the sheet's 24-point content margin — reasonable when a bar button was bare
text. Under iOS 26 the toolbar draws a glass capsule *around the padded label*,
so the padding now inflates the capsule and pushes the text off its centre.

**This is deliberate and test-enforced**, which is why it should be changed
carefully rather than quietly: `LadleTheme.Layout.sheetToolbarInset` is asserted
to equal 8 and a test scans every sheet's source for it
([DesignTokenTests.swift:329, 385](../../LadleTests/DesignTokenTests.swift:329)).
**Twelve other sheets do the same thing** — Health export, video embed, recipe
editor, reimport, sync conflicts, nutrition, correction notes, failed import,
add recipe. So the same off-centre capsule is on all of them, and the fix is to
retire the inset app-wide and update the test, not to special-case Settings.

**Effort:** medium for the Form rewrite; small for the inset, but it touches 13
files and a test that exists to prevent exactly that.

---

## 8. Settings/profile for a paid tier

> "Because I can see there being a paid version and limiting the number of
> recipes a user can add, maybe we work a little more on the settings/profile
> screen."

**Needs a decision, but the scaffolding is more real than you may remember.**
The backend already has per-user recipe quota: `GUEST_RECIPE_LIMIT = 10`, a
`RecipeCapacity` that counts saved recipes plus in-flight reservations, a
row-locked check, a `guestRecipeLimitReached` error code, and an app flow that
explains it ([limits.py](../../Backend/ladle/recipes/limits.py),
[GuestLimitView.swift](../../Ladle/Account/GuestLimitView.swift)). The limit is
keyed on `capacity.user.kind`, so a paid kind slots into the existing check
rather than needing a new mechanism.

What Settings does *not* do today: it shows "Saved recipes — 3" with no notion
of a ceiling, even for guests who have one. So a cook on 9 of 10 has no warning
until the import fails.

Whatever the tier design turns out to be, one thing is worth doing regardless
and does not depend on it: **show the quota you already enforce.** "3 of 10
recipes" for guests is honest, useful, and needs no new backend concept.

Beyond that — what a paid tier includes, what the free ceiling is, whether
billing is StoreKit — is a product decision and I have not assumed one.

**Effort:** small for surfacing the existing quota; unknown for the tier itself.

---

## 9. The sort menu

> "Honestly, the sort button opens up a menu that really doesn't look like it
> belongs in the app. It's very jarring."

**Confirmed — and it is the Recipes menu, not Discover's.** There are two sort
buttons and they behave very differently, so both were captured.

**Recipes** (capture 01) is hand-rolled: a `Menu` of plain `Button`s where the
selected row is a `Label(title, systemImage: "checkmark")` and unselected rows
are bare `Text` ([AllRecipesView.swift:79](../../Ladle/Library/AllRecipesView.swift:79)).
On screen that produces:

- a **leading** checkmark, where iOS puts selection on the trailing edge;
- an empty icon gutter on every unselected row, because only the selected row
  has a symbol;
- a heavily translucent panel that opens over the recipe photos, so the food
  shows through the menu text;
- a panel anchored far to the left, running nearly to the screen edge while its
  button sits on the right.

**Discover** (capture 02) is a `Menu` wrapping a real `Picker`
([DiscoverView.swift:300](../../Ladle/Library/DiscoverView.swift:300)) and looks
native: opaque, anchored under its button, proper checkmark column.

So the fix is to make the Recipes menu what Discover's already is — a `Picker`
bound to `viewModel.sort` — and to do the same for the display-mode menu beside
it, which has the identical checkmark-instead-of-icon problem.

**Effort:** small.

---

## 11. Pull to refresh should bring new recipes

> "Discover should refresh and show me a new list of recipes when I swipe and
> refresh."

**Partly true, and the interesting half is on the server.** The gesture already
works: `.refreshable { await viewModel.load() }`
([DiscoverView.swift:462](../../Ladle/Library/DiscoverView.swift:462)) re-fetches
page one and shows a refresh banner.

What it cannot do is show *different* recipes. The ranking is fully
deterministic by design — every sort ends in `Recipe.source_video_id` as a
tiebreak specifically so an offset cursor cannot skip or repeat rows across ties
([repository.py:157–177](../../Backend/ladle/recipes/repository.py:157)). Pull
to refresh therefore returns exactly the same rows in exactly the same order
unless the corpus changed.

Making refresh feel like refresh is a backend change, and the choice matters
because it interacts with paging:

1. **Seeded shuffle** — the client sends a seed, the server orders by a hash of
   `(seed, source_video_id)` within rank bands. Keeps paging stable within a
   session, gives a new order each pull. Cheapest of the three.
2. **Exclude recently seen** — the server remembers what it served and demotes
   it. Genuinely new results, but needs per-user state and a decay rule.
3. **Recency mix** — blend "newest" into the top of the ranking, so a pull after
   new imports surfaces them. Uses `published_at`, which is already stored but
   missing for Instagram.

Worth noting these overlap with item 2 — a "New this week" shelf would make
refresh meaningful without changing the ranking at all.

**Effort:** small (1) to medium (2).

---

## Incidental observation

Discover's demo fixture renders "One-Pot Lemon Orzo" twice as two separate rows
(captures 02, 05). Almost certainly a fixture artefact rather than the dedupe
logic, since the real feed groups by `source_video_id` — but it is worth ten
minutes to confirm it is not masking a duplicate-source case.

## How this was verified

Debug build of `6d5806a` on the "Overeast UI validation" simulator (iPhone 17,
iOS 26.5), `-demo-scenario standard`, driven by scripted taps. Captures are in
`docs/verification/captures/2026-08-31-ui-feedback-triage/`. Everything else is
read from source at the file and line cited. No code was changed.

## Open questions

1. **Item 1** — Discover-first always, or only when the library is empty?
2. **Item 2** — which Discover shape? My suggestion is sections first.
3. **Item 8** — what does the paid tier gate, and what is the free ceiling?
   (Surfacing the existing guest quota can proceed without this.)
