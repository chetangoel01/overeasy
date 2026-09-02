# Ingredient icons on the recipe detail list

Closes [#35](https://github.com/chetangoel01/recipe-app/issues/35).

## Purpose

Every row of the recipe detail's ingredient list leads with a watercolour of
the ingredient. The art was already made — 469 transparent PNGs at 1024×1024
with a manifest — so the work was never drawing; it was deciding which
painting belongs beside which line of a recipe, and proving the answer is
right often enough and wrong never.

## User-visible behavior

- Recipe detail's Ingredients tab draws a 40-point square at the head of each
  row. A painted ingredient (garlic, chicken thigh, scallion) or a tinted
  pantry container (soy sauce, kosher salt, rice vinegar), whichever the set
  filed it under.
- An ingredient the set has no honest answer for — paneer, tamarind, water, a
  fresh tomato, or a row naming two things at once — gets a `Surface.badge`
  disc with a neutral `fork.knife` at the same 40 points. No row changes
  height for want of a picture.
- The paintings sit on the porcelain ground bare, in both appearances. The
  badge disc belongs to the no-art case only.
- The art is decorative and hidden from VoiceOver. The row's text is
  unchanged and still carries all of its meaning.
- The reimport sheet reuses `IngredientList` **without** icons: there a cook
  is comparing two versions of the same text, and a column of pictures down
  the side is noise.

## Coverage, measured

The corpus is the real library: 188 distinct ingredient names over 382
occurrences, exported from `ladle_nutrition_scratch.ingredients` (a copy of
the live table) as names and counts only, and committed at
`LadleTests/Fixtures/ingredient-names.json`. The issue measured 165 names on
seventeen recipes in August; the library has grown since, so its 50% figure
is not directly comparable to these.

| Resolver | Distinct names | Occurrences |
|---|---:|---:|
| Raw name against the slugs, no tables | 71/188 — **37.8%** | 145/382 — 38.0% |
| With the synonym and default-variety tables | 147/188 — **78.2%** | 310/382 — 81.2% |
| Tables, but containers excluded | 74/188 — **39.4%** | 142/382 — 37.2% |

`IngredientIconResolverTests` holds the floor at 78% on distinct names and
prints both figures on every run.

That third row is the decision this ticket turned on. The set files almost
all of its produce, meat, dairy and fresh herbs as paintings and almost all
of its pantry — every oil, spice, sauce, pulse, sweetener and vinegar — as a
tinted jar or bottle. "Illustrated ingredients only" and "every row gets a
picture" cannot both hold: dropping the containers costs 39 points of
coverage — the bare rows go from one in five to three in five, worst in
exactly the South Asian recipes this library is full of. The owner chose the
containers back in, and `testExcludingContainersCostsMostOfTheCoverage` keeps
that measurement honest rather than leaving it as a claim in a pull request.

The 41 names still unresolved are almost all real holes in the art —
`paneer`, `tamarind`, `water`, a fresh tomato, `pecorino`, `fontina`,
`cottage cheese`, ground turkey, marinara, besan — or rows too vague to
illustrate honestly: `salt & pepper`, `spices`, `fresh herbs`, `beans`,
`cheese`, `noodles`, `unknown ingredient`. Each of those draws the badge.

## How the matching works

`Ladle/Design/IngredientIconResolver.swift` is a pure function from a name to
an optional slug. **It never matches on a substring.** "peanut butter"
containing "butter" is the whole problem, and the issue is explicit that the
wrong painting is worse than none, because a cook reads the picture before
the words. So both sides — the ingredient name and the slug — go through one
normaliser and must come out as equal token *sets*.

Normalising: strip parentheticals, fold diacritics, lowercase, split on
non-alphanumerics, fold plurals with the `len > 3 && hasSuffix("s")` rule
`Backend/ladle/nutrition/calculator.py` already uses, drop connectives, drop
single characters and bare numbers. Because both sides are mangled
identically, the words the blunt rule gets wrong (`asparagus` → `asparagu`)
still match by construction; `irregulars` covers only the forms where one
side would be mangled and the other not, such as a recipe's "bay leaves"
against the set's `bay-leaf`.

Then three passes, each looser than the last, first hit wins:

1. **Literal** — every token. `diced tomatoes` → `tomatoes-diced`, and only
   here.
2. **Without preparation words** — `finely chopped garlic` → `garlic`.
3. **Without soft qualifiers** — `low-sodium soy sauce` → `soy-sauce`. Last,
   because these are often the point: `basil-fresh` and `basil-dried` are
   different pictures and pass 1 has already had its chance.

Within a pass: the 469-slug index, then the synonym table (74 entries), then
the default-variety table (51), then all three again with one token
substituted (`powder`→`ground`, `broth`→`stock`) — late enough that
`garlic-powder` and `curry-powder` win on their own spelling before `powder`
ever becomes `ground`.

Two rules keep the wrong art out:

- **No trailing-token stripping.** The brief allowed dropping trailing
  qualifiers and retrying; that is precisely the wrong-art generator.
  `peanut butter` → `peanut`, `coconut milk` → `coconut`, `chicken stock` →
  `chicken-*`, `onion powder` → `onion-yellow`, `rice vinegar` → `rice-*` all
  come from dropping a head noun. Nothing is ever dropped except from the
  named preparation and soft-qualifier lists, and a name only reaches a slug
  it does not spell through a table somebody wrote on purpose.
- **Preparation words come out of names, never out of slugs.** A slug's own
  words were all chosen. Filtering them symmetrically collapses
  `tomatoes-crushed` and `tomatoes-diced` onto one key, and then a fresh
  tomato — which has no painting at all — gets a can drawn beside it. Only
  the connectives come out of both, which is how `hearts of palm` reaches
  `hearts-of-palm`.

`IngredientIconResolverTests` carries a 28-name negative list asserting each
resolves to *nothing*, and a 48-name positive list for the names that look
like traps but have a right answer (`eggplant`, `buttermilk`,
`butternut squash`, `coconut milk` → `milk-coconut`, `chicken stock` →
`stock-chicken`, `cream cheese` → `cheese-cream`).

## Asset pipeline

`Tools/ingredient-icons/build.sh` takes the masters path, reads their
`manifest.json`, downscales with `sips -Z 192`, and writes three generated
artefacts from one read so they cannot drift apart:

| Artefact | What it is |
|---|---|
| `Ladle/Resources/IngredientIcons.xcassets/<slug>.imageset/` | 469 image sets, PNG in the `2x` universal slot with `1x` and `3x` declared empty, the shape [2026-07-29-asset-catalog-scale-slots](2026-07-29-asset-catalog-scale-slots.md) settled |
| `Ladle/Resources/IngredientIcons.xcassets/manifest.json` | slug, display name, category and container for what shipped |
| `Ladle/Design/IngredientIconCatalogue.swift` | the 469-slug universe as static Swift, so the resolver stays pure |

The 505 MB of 1024×1024 masters never enter git: git cannot forget a blob
once it has one. They stay in `~/Downloads/cooking-app-icons-complete` and
the script is re-runnable against them.

192px is 2× the icon set README's 96-point tile target and 4.8× the 40-point
row this app actually draws them in, so a 3× phone has more pixels than it
needs. 96px would be soft; 288px more than doubles the weight for detail no
row can show.

### Weight

| | Before | After | Delta |
|---|---:|---:|---:|
| `Ladle.app`, Release simulator build | 35,228 KB (34 MB) | 51,848 KB (51 MB) | **+16,620 KB (+16.2 MB)** |
| `Assets.car` inside it | 5,375,560 B (5.1 MB) | 22,272,984 B (21.2 MB) | **+16,897,424 B (+16.1 MB)** |

Both builds are `xcodebuild -configuration Release -destination 'platform=iOS
Simulator,name=iPhone 17'` with their own derived-data directory, the "before"
taken from a clean `origin/main` tree. The catalogue is 23 MB on disk as 469
loose PNGs; `actool` recompresses it to 16.1 MB in `Assets.car`, and that is
what actually ships. The issue's estimate for all 469 at 192px was 23 MB, so
the real cost is about a third under it.

## Important decisions

- **Containers are eligible art** (the owner's choice, option 1 of the
  implementation brief). `includesContainers` defaults to `true`; the flag
  exists so the decision stays visible and reversible, and
  `testExcludingContainersCostsMostOfTheCoverage` records what the other
  choice cost.
- **The no-art glyph is `fork.knife`.** It says "an ingredient" and nothing
  about which one. Every category-shaped glyph — `leaf`, `drop`, `carrot` —
  is a claim about the row, and getting that claim wrong is the failure this
  feature exists to avoid. Paneer is not a leaf. It is drawn at
  `IconSize.medium` rather than `small` because 13 points is lost inside a
  40-point disc. The Discover tab also uses `fork.knife`; a quiet
  secondary-ink glyph inside a badge in a content row is not mistakable for a
  tab bar item.
- **Dark mode does *not* put a disc behind the paintings** — checked, not
  assumed. The set's README warns against dark grounds and the brief said to
  add a `Surface.badge` disc in dark "if they vanish", so
  `Tools/ingredient-icons/dark-ground-check.swift` composites the darkest
  candidates — bay leaf, spinach, kale, basil, cilantro, chard, aubergine,
  blackberry, nigella seeds — onto `porcelain` at both #F2F4F6 and #101214,
  bare and on a #303840 disc. `captures/…/dark-ground-check.png` is the
  result. Nothing vanishes: the leaves are bright mid-greens with far more
  contrast against near-black than against paper, and even the aubergine
  keeps its highlights and stem. The disc version is worse — it reads heavy,
  turns a list of ingredients into a list of settings rows, and clips the
  art that reaches past a 40-point circle (garlic and chard both do). So the
  paintings stay bare and the disc keeps its one job: standing in where
  there is no art.
- **`project.yml` needed no change.** `Ladle` already declares
  `resources: - path: Ladle/Resources`, and `LadleTests` declares
  `sources: - path: LadleTests`; XcodeGen picks up the new asset catalogue
  and `Fixtures/ingredient-names.json` from those directory references, the
  same way `Assets.xcassets` has always been picked up. An explicit entry
  would have duplicated them.
- **`IngredientIconCatalogue.swift` lands with the resolver, not with the
  asset catalogue**, even though `build.sh` generates it. The resolver cannot
  compile without the slug universe, and a commit that does not compile is
  worse than one whose tests are red on purpose.
- **Default varieties are chosen, and refused where the word is genuinely
  ambiguous.** `salt` → `salt-kosher`, `sugar` → `sugar-granulated`,
  `olive oil` → `olive-oil-evoo`, `bell pepper` → `bell-pepper-red`,
  `rice` → `rice-jasmine`, `paprika` → `paprika-sweet`. A bare herb the set
  has both ways means the fresh one — one rule for all of them, because a
  recipe that means dried says "dried". `beans`, `cheese`, `noodles`,
  `peppers` and `oil`-alone get no default and stay unillustrated.
- **The 40-point square does not scale with Dynamic Type.** The brief asked
  for a fixed square and the label origin and divider inset derive from it,
  so it stays a constant. At accessibility-large the art is visibly smaller
  relative to the text (`after-light-accessibility.png`) but still reads as
  the row's subject, and `.center` alignment keeps it tied to a row that has
  wrapped to three lines. A `@ScaledMetric` square is the obvious follow-up
  if it ever looks lost; it would need `dividerInset` to take the scaled
  value too.
- **A fruit's juice or zest is drawn as the fruit** (`lemon juice` → `lemon`).
  A deliberate exception to "never drop a head noun", made in the table by
  hand: the set has no juice art and a lemon beside "lemon juice" reads
  correctly.

## Affected components

- `Ladle/Design/IngredientIconResolver.swift` — new; the matcher and its tables.
- `Ladle/Design/IngredientIconCatalogue.swift` — new, generated; the slug universe.
- `Ladle/Resources/IngredientIcons.xcassets/` — new, generated; 469 image sets.
- `Ladle/RecipeDetail/IngredientList.swift` — `showsIcons`, the 40-point
  leading square, the derived label origin.
- `Ladle/RecipeDetail/RecipeDetailView.swift` — passes `showsIcons: true`.
- `Ladle/Edit/ReimportSheet.swift` — unchanged; keeps the default `false`.
- `Tools/ingredient-icons/build.sh` — new; the downscale pipeline.
- `LadleTests/IngredientIconResolverTests.swift`, `LadleTests/Fixtures/ingredient-names.json` — new.
- `PRODUCT.md`, `DESIGN.md` — the anti-references list said "illustrated food
  metaphors"; this is the exception, and the docs now say so rather than
  contradicting the build.

## Verification

Red first, at the resolver commit's exact tree — the fixture and the asset
catalogue had not landed yet:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests/IngredientIconResolverTests
→ Executed 9 tests, with 3 failures (0 unexpected)
```

The three were the coverage floor, the containers comparison and the bundled
art — the tests that need the two artefacts still to come. The negative list,
the positive list and the table checks passed on the resolver alone.

Green, with everything in place:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests
→ Executed 417 tests, with 1 test skipped and 0 failures (0 unexpected)
  in 4.875 seconds — ** TEST SUCCEEDED **

xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleUITests
→ Executed 20 tests, with 0 failures (0 unexpected) in 285.014 seconds
  — ** TEST SUCCEEDED **
```

`** BUILD INTERRUPTED **` at the end of each log is the watchdog. The
`xcodebuild test` process prints its results on this machine and then never
exits, so it runs under a timer and the log is read for the totals.

Also run: `git diff --check` before every commit; `sips -g pixelWidth
-g hasAlpha` spot-checks on the generated PNGs (192×192, alpha intact).

## Captures

`docs/verification/captures/2026-09-02-ingredient-icons/`, taken on the
Overeast UI validation simulator (`614AF85D-…`) launched with `-ui-testing
-onboarding-complete`, status bar frozen at 9:41.

| File | What it shows |
|---|---|
| `before-light-default.png` | Sheet-Pan Gochujang Chicken on `main` — bullets |
| `before-dark-default.png` | the same, dark |
| `before-light-accessibility.png` | the same, accessibility-large type |
| `before-burgers-light.png` | Crispy Chili Oil Smash Burgers on `main` |
| `before-burgers-dark.png` | the same, dark |
| `after-light-default.png` | Gochujang Chicken: nine rows, painted and container |
| `after-dark-default.png` | the same, dark |
| `after-light-accessibility.png` | the same at accessibility-large type |
| `after-burgers-light.png` | Smash Burgers: three rows with no art, badged |
| `after-burgers-dark.png` | the same, dark |
| `dark-ground-check.png` | fourteen paintings on light and dark porcelain, bare and on a badge disc — the evidence for the decision above |

Gochujang Chicken is the mixed case — `chicken-thigh`, `garlic` and
`scallion` painted; `gochujang`, `honey`, `soy-sauce`, `vinegar-rice`,
`sesame-oil-toasted` and `rice-jasmine` as containers. Smash Burgers is the
degraded case: American cheese, potato rolls and chili crisp have no art in
the set and take the badge, beside painted beef and onion and three
containers.
