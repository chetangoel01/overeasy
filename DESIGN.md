# Ladle Design System — "Porcelain & Graphite"

Status: approved implementation source of truth

## Concept

Overeasy should feel like a focused iPhone utility, not a themed recipe app.
Cool porcelain surfaces recede behind food photography, graphite makes cooking
calm and legible, and a user-selected accent marks actions or active items.
Signal red remains the default.

## Scene

A home cook saves and sorts recipes one-handed on the couch, then reads the app
from a bright kitchen counter with wet or floury hands. Browsing is compact and
familiar. Cooking is high contrast and readable at a glance.

## Design principles

- Prefer native iOS navigation, sheets, menus, controls, safe areas, SF Symbols,
  and system feedback.
- Show the object and the action before explaining either one. Instructional
  copy appears only when a consequence or recovery path is not obvious.
- Food photography is the most saturated element in the library.
- The selected accent appears for primary actions, favorites, active
  navigation, and attention badges, never as decoration. Destructive actions
  continue to use the system destructive role.
- Use flat or material-backed native surfaces without decorative gradients,
  outlines, or ornamental shadows.
- Preserve Dynamic Type, VoiceOver, Reduce Motion, and 44-point targets.

## Color

Every colour has a semantic role in `LadleTheme`. Call sites reach for the
role, which says what the colour is *for*. The palette name says only what it
*is*; it stays because the roles are defined in terms of it, not as a second
name a call site may use.

| Role | Semantic name | Palette name | Light | Dark | Use |
| --- | --- | --- | --- | --- | --- |
| Porcelain | `Surface.porcelain` | `paper` | `#F2F4F6` | `#101214` | Primary surface |
| Raised neutral | `Surface.raised` | `oat` | `#E3E7EA` | `#1C2024` | Fields and quiet grouping |
| Steel | `Surface.steel` | `ube` | `#D7DDE2` | `#252A2F` | Inactive and review surfaces |
| Graphite ground | `Surface.graphite` | `plum` | `#14181B` | `#101214` | Welcome and Focus Mode |
| Badge | `Surface.badge` | — | `#CDD5DC` | `#303840` | Icon badge on a raised card |
| Graphite ink | `Label.primary` | `ink` | `#14181B` | `#F2F4F5` | Primary text and controls |
| Secondary ink | `Label.secondary` | `mutedInk` | `#64707A` | `#A6AFB7` | Metadata |
| On-signal | `Label.onAccent` | `onAccent` | `#FAFBFC` fixed | same | Content on accent or graphite |
| Fixed graphite | `Label.onFixedPale` | `fixedInk` | `#14181B` fixed | same | Content on fixed pale surfaces |
| Accessible accent text | `Label.accent` | `accentText` | `#C73924` default | `#FF7562` default | Favorites and tinted icons |
| Selected accent fill | `Intent.accent` | `brick` | `#EE4B2F` default | `#FF674E` default | Primary action and active state |
| Destructive | `Intent.destructive` | — | system red | system red | Delete and discard |
| Sage success | `Intent.success` | `celery` | `#83A18A` | `#294233` | Success state |
| Focus signal | `Intent.focus` | `focusAccent` | `#FF5A3D` fixed | same | Focus progress and advance |
| Disabled | `Intent.disabledFill` / `disabledLabel` | — | steel / secondary ink | same | Any disabled control |

`Surface.badge` exists because `Surface.steel` sits about four percent off
`Surface.raised`: a badge drawn in steel on a raised card disappears into it.
Badges on the porcelain ground may keep using steel.

The four compatibility aliases — `field`, `review`, `success` and `paprika` —
are gone; every call site is on the role. The duplicate, unused `butter` palette
entry is removed as well.


Accent fills always carry `onAccent`. Settings offers Tomato, Orange, Sage,
Blue, and Purple. The selected value is local and persistent. Focus Mode keeps
its fixed `focusAccent`, and errors use the system destructive role.

## Typography

All type uses SF Pro's standard design and width. Text uses a role from
`LadleTextStyle`, never a size — and each role is a system text style, so the
sizes below are iOS's, not ours. A role names what the text is *for*; the
platform decides how big that is. This is why the app matches the metrics of
every other iOS app and tracks the system at every Dynamic Type setting rather
than only approximating it at the default one.

| Role | Text style | Size at default | Weight | Use |
| --- | --- | --- | --- | --- |
| `display` | `.largeTitle` | 34 | bold | Welcome or Focus headline that owns the screen |
| `title` | `.title` | 28 | bold | Screen title, cooking instruction |
| `recipeTitle` | `.title3` | 20 | semibold | A recipe's name as content |
| `section` | `.headline` | 17 | system | Section heading above a group |
| `body` | `.body` | 17 | system | Running text |
| `bodyStrong` | `.body` | 17 | semibold | Emphasis, and every button label |
| `metadata` | `.footnote` | 13 | system | Counts, sources, supporting detail |
| `eyebrow` | `.caption` | 12 | semibold | Uppercase label above a title, Focus Mode only |

"System" weight means the role does not override the text style's own weight.
`.headline` is already semibold on iOS; restating that here would freeze it if
the platform ever changed.

`recipeTitle` and `section` are not interchangeable: `recipeTitle` is `.title3`
because a recipe name is content and should grow with the reader's size, and
`section` is `.headline` because a section label is chrome and stays closer to
the surrounding UI. They diverge at large Dynamic Type, which is the point.

`ladleScaledFont(size:)` is for cooking surfaces needing distance legibility
beyond `display`, and nothing else. Symbol point sizes use `LadleTheme.IconSize`
— `small` 13, `medium` 16, `large` 20, `feature` 28, `hero` 38.

Metadata is always paired with `Label.secondary`. Avoid expanded display type,
serif editorial accents, and decorative uppercase tracking.

Control labels are sentence case: "Start cooking", not "Start Cooking".

## Shape and spacing

The scale is 4, 8, 12, 16, 24, and 32 points. A padding or stack spacing that
is not one of those six is a bug — reach for the `LadleTheme.Layout` role that
names the value instead of the raw number.

| Role | Value | Use |
| --- | --- | --- |
| `Layout.screenMargin` | 16 | Leading and trailing margin on a workspace screen |
| `Layout.sheetMargin` | 24 | Margin inside a sheet's content |
| `Layout.cardPadding` | 16 | Inner padding of a grouped card or field |
| `Layout.sectionGap` | 24 | Between two sections of a screen |
| `Layout.rowGap` | 12 | Between sibling rows |
| `Layout.iconGap` | 12 | Between an icon and the label it introduces |

Control heights are three values, not six: `Control.hitTarget` 44 (minimum
interactive target, never smaller), `Control.field` 48 (text fields and
tappable rows), `Control.primary` 52 (filled buttons).

Corners: `control` 15 for controls and fields, `card` 20 for grouped surfaces
and recipe images, `thumbnail` 12 for small artwork where 20 reads as too round,
`sheet` 34. Sheets keep the native presentation shape and drag indicator.

A divider that separates rows carrying a leading icon is derived with
`LadleTheme.dividerInset(iconWidth:gap:leadingPadding:)` so it lands on the
label, and cannot drift when the icon or gap changes. Do not hardcode it.

A sheet's close or cancel control sits where the system puts it, inside its own
glass capsule. A sheet does not pad its toolbar items: `sheetMargin` is for the
content beneath them.

## Buttons

Four roles, in `LadleButtonRole`. A button that is none of them has not been
designed — pick the closest role rather than assembling one out of a background
and a font.

| Role | Fill | Label | Use |
| --- | --- | --- | --- |
| `primary` | `Intent.accent` | `Label.onAccent` | The one action the screen exists to perform |
| `secondary` | `Surface.raised` | `Label.primary` | A real alternative shown beside the primary |
| `destructive` | `Intent.destructive` | `Label.onAccent` | Deletes or discards |
| `tertiary` | none | `Label.accent` | Low-commitment action, often an escape |

Primary, secondary and destructive span their container, so a column of them
shares one width and one left edge. Tertiary hugs its label.

Disabled controls drop their fill rather than fading it. A faded accent still
reads as an accent button, and at the opacity that made it look disabled its
label fell near two to one against its own fill.

Icon-only controls are `LadleIconButton`, always on a 44-point target however
small the glyph.

Buttons that carry both an icon and a label align their labels to a shared
leading edge; centring icon and label together as one group gives a column of
buttons a different text origin per button.

## Navigation and library

- The root workspace is a native four-tab structure: Recipes, Discover, Watch,
  and Inbox.
- Discover is the default tab — a launch lands on something to read rather
  than on the cook's own shelf — except when its feed fails on a cold launch,
  which opens Recipes instead, silently and once, so the first screen is never
  an error. Any Discover failure after that shows Discover's own error state,
  and a slow feed keeps its skeleton rather than bouncing.
- Recipes, Watch, and Inbox are direct workspace destinations, not cards
  hidden inside a home feed.
- Inbox shows a badge only when imports need attention.
- Recipes owns the large title, an always-visible search field, compact sort,
  filter, and grid/list controls, an image-led recipe archive, and generated
  collections below the archive.
- Grid/List is an explicit menu and persists locally. The grid uses adaptive
  columns with square artwork, then becomes one column for large Dynamic Type.
- Selecting a tab returns to that workspace root instead of pushing a faux
  destination onto the recipe navigation path.
- Recipe detail remains a pushed destination. Import and account flows remain
  native sheets.
- Account management stays in the top-right toolbar on Recipes, Discover,
  Watch, and Inbox. Add Recipe sits beside it on Recipes and Inbox, the two
  tabs where a link arrives; Discover and Watch are consumption surfaces and
  carry no import affordance.

## Watch and Inbox

- Watch is a vertically paged, full-viewport feed. Each swipe settles on one
  video recipe with the provider's supported inline player already loaded as a
  full-bleed background. A provider may still require its own first Play tap.
- Compact Pause or Resume, Mute or Unmute, account, recipe, and cooking actions
  overlay top and bottom scrims, with the tab bar still visible. Mute state
  follows the user between recipes. Watch never opens a browser.
- Only the visible recipe owns a player. Paging away or backgrounding the app
  suspends that media, while the next settled recipe loads its player without
  another Ladle Play step.
- TikTok uses Player for Web, YouTube uses the IFrame player, and Instagram uses
  its reel/post embed. These are in-app web players, not raw media URLs or
  `AVPlayer`, because the providers do not expose a durable direct-video
  contract. Unknown URL shapes show an unavailable state instead of falling
  back to a social webpage.
- Video recipes are shuffled once when the library session loads. Refreshes
  preserve the active order so favorite and sync updates never move content
  beneath the user.
- Do not reproduce recipe detail inside segmented card panels.
- Inbox is a plain native list. Empty copy is one short sentence. Recovery and
  review actions remain explicit when an import needs attention.

## Cooking

- Full Recipe stays a light checklist and overview.
- Focus Mode uses the graphite ground with porcelain text and a fixed signal-red
  progress/action color.
- One instruction owns the screen. Timers are large and stateful.
- Food photography and library navigation do not appear in Focus Mode.

## First run and Share Extension

- Welcome is a dedicated graphite surface with the installed app mark, one
  product sentence, and Apple, Google, and guest choices.
- State the ten-recipe guest limit because it changes the user's decision; avoid
  a passive feature tour.
- The Share Extension mirrors the porcelain/graphite palette and says only what
  is needed to confirm saving or explain recovery.
- Recipe processing remains owned by the app when its sheet is dismissed. Close
  and Keep browsing return to the library without cancelling the durable job.

## Discover and account

- Discover ranks public recipe-video sources by aggregate saves and shows the
  creator account, source, image, summary, and save count. Tapping a result opens
  the complete shared extraction as a read-only recipe preview. Saving clones
  that already-resolved extraction into the current account. Neither action
  resubmits the video to the import, transcription, or model pipeline.
- Two shelves sit above that ranked list, because Discover is the launch screen
  and a list ordered by saves only turns over when someone saves something.
  **New to Overeasy** is ordered by when a source arrived here, not when its
  creator published it. **Quick dinners** keeps the sources a saver timed at
  thirty minutes or less; a source nobody timed is left out rather than assumed
  quick. Each rail is one short page of the same feed — no "See all", no
  destination of its own — and the list beneath it is headed "All recipes".
- A rail is decoration on top of the feed, so it fails quietly: a shelf that
  does not load is absent rather than an error, and a shelf with fewer than
  three cards is dropped instead of drawn short. Searching hides both rails
  outright, because search replaces the feed and unsearched cards beside the
  results would read as results.
- Scrolling back to the top of Discover fetches a fresh page 1 quietly and, if
  it differs from what is on screen, offers it as a "New recipes" pill in the
  same bar the refresh banner uses — the list only moves when the cook taps it,
  because scrolling up is how someone returns to a row they meant to keep.
- Discover excludes sources already saved by the current account and removes a
  row as soon as its direct save completes.
- Recipe cards and Discover results use the native long-press context menu as
  the modern replacement for 3D Touch. The menu previews the recipe and exposes
  Open plus a non-destructive Save or Favorite action.
- Settings opens on the cook: a 64-point avatar — the provider's photo or a
  monogram, whichever they choose — the editable display name, and the account
  kind beneath it. A guest sees the word "Guest" and a sign-in button, and
  nothing else. Beneath that header sit accent color, saved-recipe count, and
  sync state. Internal installation identifiers stay hidden.

## Accessibility and verification

- Test default, extra-large, and accessibility Dynamic Type sizes.
- Verify light and dark cooking surfaces and VoiceOver labels.
- Verify 44-point targets and WCAG AA contrast for small text.
- Capture Recipes, Discover, Watch, Inbox, Settings, recipe detail, Focus Mode,
  welcome, and Share Extension at the project simulator size before a design
  checkpoint.
