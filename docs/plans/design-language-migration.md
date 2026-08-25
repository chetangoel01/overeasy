# Design language migration

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

`10` and `14` together account for 64 uses. They are not typos; they are a
second scale that grew because nothing named the first one's roles.

| Found | Uses | Move to |
| --- | --- | --- |
| 10 | 33 | 8 (`compact`) or 12 (`medium`) |
| 14 | 31 | 12 (`medium`) or 16 (`regular`) |
| 13 | 10 | 12 (`medium`) |
| 22 | 10 | 24 (`generous`) |
| 6 | 9 | 4 (`tight`) or 8 (`compact`) |
| 7 | 6 | 8 (`compact`) |
| 20 | 6 | 16 (`regular`) or 24 (`generous`) |
| 5, 3, 2 | 12 | 4 (`tight`) |
| 26, 28, 30, 36, 40, 48, 52, 60, 61 | 12 | Nearest step, or a `Layout` role |

Control heights fold into three: 46 and 48 to `Control.field`; 50, 52 and 56 to
`Control.primary`; 44 stays `Control.hitTarget`.

Densest files first — these six hold about half the off-scale values:
`AccountSheet` 13, `AddRecipeSheet` 12, `RecipeEditorView` 12, `ReimportSheet`
10, `DiscoverView` 9, `FullRecipeView` 9.

## Colour

Replace the alias pairs, then the palette names, with semantic roles. No colour
values change; `Surface.badge` is the only new value.

| Replace | With | Uses |
| --- | --- | --- |
| `paprika` | `Label.accent` | 51 |
| `field` | `Surface.raised` | 28 |
| `review` | `Surface.steel` | 28 |
| `success` | `Intent.success` | 10 |
| `ink` | `Label.primary` | 176 |
| `onAccent` | `Label.onAccent` | 51 |
| `paper` | `Surface.porcelain` | 45 |
| `mutedInk` | `Label.secondary` | 30 |

`butter` has zero uses. Its `butterHex` constant is asserted in
`DesignTokenTests`, so remove both together or neither.

Icon badges drawn on a raised card move to `Surface.badge`; badges on the
porcelain ground may stay on `Surface.steel`.

## Buttons

Move the 79 `Button` declarations that bypass the Ladle styles onto
`LadleButtonStyle`. Two behaviours only the roles can fix:

- Delete actions become `.destructive`. In the recipe options sheet, delete is
  currently indistinguishable from four benign actions.
- Icon-and-label buttons stop centring the pair as one group. The failed-import
  recovery stack currently gives its three buttons three different label
  origins, spanning 19pt.

## Known layout defects this unblocks

Each has a role that now exists to express the fix:

- Recipe grid columns capped at `maximum: 146` centre the grid 31pt inside the
  `screenMargin` every other element uses; at XXXL Dynamic Type the single
  column strands 128pt from the leading edge.
  `AllRecipesView.swift:315`.
- Cooking checklist dividers are hardcoded to 52 while their rows put labels at
  43. `FullRecipeView.swift:162` — use `dividerInset(iconWidth:gap:)`.
- Sheet close controls sit on 16 while sheet bodies sit on 24, across seven
  screens. Focus Mode is the only one already correct.
- Sign in with Apple reads `colorScheme` before the forced-dark override, so it
  renders black on graphite in light appearance.
  `WelcomeView.swift:141`.

## Sequencing

1. Colour aliases (mechanical, no visual change).
2. Off-scale spacing, densest files first.
3. Button roles, which carries the two behaviour fixes above.
4. The layout defects, which are call-site changes rather than token changes.

Steps 1 and 2 should be visually identical where they only round to a
neighbouring step; capture Recipes, a sheet, and Focus Mode before and after
each file to confirm.
