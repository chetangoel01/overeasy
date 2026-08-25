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

Legacy token names remain in code while their semantic roles settle.

| Role | Code token | Light | Dark | Use |
| --- | --- | --- | --- | --- |
| Porcelain | `paper` | `#F2F4F6` | `#101214` | Primary surface |
| Raised neutral | `oat` | `#E3E7EA` | `#1C2024` | Fields and quiet grouping |
| Steel | `butter`, `ube` | `#D7DDE2` | `#252A2F` | Inactive and review surfaces |
| Graphite ink | `ink` | `#14181B` | `#F2F4F5` | Primary text and controls |
| Graphite ground | `plum` | `#14181B` | `#101214` | Welcome and Focus Mode |
| Selected accent fill | `brick` | `#EE4B2F` default | `#FF674E` default | Primary action and active state |
| Accessible accent text | `accentText` | `#C73924` default | `#FF7562` default | Favorites and tinted icons |
| Sage success | `celery` | `#83A18A` | `#294233` | Success state |
| Secondary ink | `mutedInk` | `#64707A` | `#A6AFB7` | Metadata |
| On-signal | `onAccent` | `#FAFBFC` fixed | same | Content on signal red or graphite |
| Fixed graphite | `fixedInk` | `#14181B` fixed | same | Content on fixed pale surfaces |
| Focus signal | `focusAccent` | `#FF5A3D` fixed | same | Focus progress and advance action |

Accent fills always carry `onAccent`. Settings offers Tomato, Orange, Sage,
Blue, and Purple. The selected value is local and persistent. Focus Mode keeps
its fixed `focusAccent`, and errors use the system destructive role.

## Typography

All type uses SF Pro's standard design and width.

- Screen titles and welcome headlines: bold.
- Recipe names and section headings: semibold.
- Body: regular; action emphasis: semibold.
- Metadata: regular and secondary in color.
- Long cooking instructions can use larger scaled sizes for distance legibility.

Avoid expanded display type, serif editorial accents, and decorative uppercase
tracking.

## Shape and spacing

- Icon controls have at least a 44-point target.
- Controls and fields use 14–16 point continuous corners.
- Recipe images and grouped surfaces use 18–22 point continuous corners.
- Sheets keep the native presentation shape and drag indicator.
- Use the 8, 12, 16, 24, and 32 point spacing roles.

## Navigation and library

- The root workspace is a native four-tab structure: Recipes, Discover, Watch,
  and Inbox.
- Recipes is the default tab. Discover, Watch, and Inbox are direct workspace
  destinations, not cards hidden inside a home feed.
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
  Watch, and Inbox. Add Recipe remains specific to Recipes.

## Watch and Inbox

- Watch is a vertically paged, full-viewport feed. Each swipe settles on one
  video recipe with full-bleed artwork, source and creator attribution, and
  direct Play, Favorite, Share, Open, and Start Cooking actions.
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
- Discover excludes sources already saved by the current account and removes a
  row as soon as its direct save completes.
- Recipe cards and Discover results use the native long-press context menu as
  the modern replacement for 3D Touch. The menu previews the recipe and exposes
  Open plus a non-destructive Save or Favorite action.
- Settings presents accent color, connected provider, saved-recipe count, and
  sync state. Internal installation identifiers and provider profile details
  stay hidden.

## Accessibility and verification

- Test default, extra-large, and accessibility Dynamic Type sizes.
- Verify light and dark cooking surfaces and VoiceOver labels.
- Verify 44-point targets and WCAG AA contrast for small text.
- Capture Recipes, Discover, Watch, Inbox, Settings, recipe detail, Focus Mode,
  welcome, and Share Extension at the project simulator size before a design
  checkpoint.
