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
| Porcelain | `Surface.porcelain` | `paper` | `#F7F4EF` | `#101214` | Primary surface |
| Raised neutral | `Surface.raised` | `oat` | `#ECE7E1` | `#1C2024` | Fields and quiet grouping |
| Steel | `Surface.steel` | `ube` | `#E3DDD6` | `#252A2F` | Inactive and review surfaces |
| Graphite ground | `Surface.graphite` | `plum` | `#14181B` | `#101214` | Welcome and Focus Mode |
| Badge | `Surface.badge` | — | `#CDD5DC` | `#303840` | Icon badge on a raised card |
| Graphite ink | `Label.primary` | `ink` | `#14181B` | `#F2F4F5` | Primary text and controls |
| Secondary ink | `Label.secondary` | `mutedInk` | `#505B64` | `#A6AFB7` | Metadata |
| On-signal | `Label.onAccent` | `onAccent` | `#FAFBFC` fixed | same | Content on accent or graphite |
| Fixed graphite | `Label.onFixedPale` | `fixedInk` | `#14181B` fixed | same | Content on fixed pale surfaces |
| Accessible accent text | `Label.accent` | `accentText` | `#C73924` default | `#FF7562` default | Favorites and tinted icons |
| Selected accent fill | `Intent.accent` | `brick` | `#C23B26` default | `#C23B26` default | Primary action and active state |
| Destructive | `Intent.destructive` | — | system red | system red | Delete and discard |
| Sage success | `Intent.success` | `celery` | `#83A18A` | `#294233` | Success state |
| Protein mark | `Mark.protein` | `thyme` | `#5A8767` | `#83A18A` | Protein's dot and bar segment on the nutrition sheet |
| Focus signal | `Intent.focus` | `focusAccent` | `#FF5A3D` fixed | same | Focus progress and icons |
| Focus / destructive button fill | `Intent.focusFill` / `Intent.destructiveFill` | `#C23B26` fixed | same | White-label actions |
| Disabled | `Intent.disabledFill` / `disabledLabel` | — | steel / secondary ink | same | Any disabled control |

`Surface.badge` exists because `Surface.steel` sits about four percent off
`Surface.raised`: a badge drawn in steel on a raised card disappears into it.
Badges on the porcelain ground may keep using steel.

`Mark` holds colours that stand for data — a chart segment and the legend dot
that names it. A mark is a graphic, so it answers to 3:1 against the surfaces
it sits on, steel and raised, in both appearances. `Mark.protein` exists
because `Intent.success` is a fill: its dark value is there for light text to
sit on, and drawn as a mark it is about 1.3:1 against steel. The mark stays in
the same sage family, at 3.1:1 on steel and 3.3:1 on raised in light, and
5.1:1 and 5.8:1 in dark.

The four compatibility aliases — `field`, `review`, `success` and `paprika` —
are gone; every call site is on the role. The duplicate, unused `butter` palette
entry is removed as well.


Accent fills always carry `onAccent`. Settings offers Tomato, Orange, Sage,
Blue, and Purple. The selected value is local and persistent. Focus Mode keeps
its bright fixed `focusAccent` for progress and its darker `focusFill` for the
Next button. Errors and native destructive controls use system red; filled
destructive buttons use `destructiveFill`. All five selected accent fills and
secondary text on paper, raised, and steel meet 4.5:1 in light and dark mode.
Supporting recipe facts use `Label.secondary` without reducing its opacity.

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
| `compactTitle` | `.title2` | 22 | bold | Screen title sharing a row with artwork, as in the recipe header |
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

`ladleScaledFont(size:)` is for cooking surfaces read from counter distance —
the Focus Mode instruction, its ingredient rows, a timer's clock — and nothing
else. Symbol point sizes use `LadleTheme.IconSize` — `small` 13, `medium` 16,
`large` 20, `feature` 28, `hero` 38.

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
| `destructive` | `Intent.destructiveFill` | `Label.onAccent` | Deletes or discards |
| `tertiary` | none | `Label.accent` | Low-commitment action, often an escape |

Primary, secondary and destructive span their container, so a column of them
shares one width and one left edge. Tertiary hugs its label.

Disabled controls drop their fill rather than fading it. A faded accent still
reads as an accent button, and at the opacity that made it look disabled its
label fell near two to one against its own fill. Pressed filled buttons darken
the fill without fading their label.

Icon-only controls are `LadleIconButton`, always on a 44-point target however
small the glyph. The circle it draws may be smaller than the target
(`diameter`), and on a raised card it takes the `onCard` tone, because steel
disappears there.

Buttons that carry both an icon and a label align their labels to a shared
leading edge; centring icon and label together as one group gives a column of
buttons a different text origin per button.

Inline filled actions such as Discover Save use the same 52-point minimum,
body label and 15-point corner as full-width actions. They hug their label
with regular horizontal padding. Loading reserves the original label's bounds
and accessible name, with an overlaid spinner. The caller disables repeated
submission. A completed Save shows a neutral, disabled “Saved” checkmark;
failures leave the action available beside an explanatory message.

List and grid favorites share the icon button's glyph, 44-point target, selected
accent, and press feedback. List favorites have no fill. Grid favorites use a
material circle to maintain contrast over photographs; that is an intentional
surface difference, not a different control size.

A glyph that changes with state — a favorite, play and pause, the timer ring,
a completed step — morphs with SF Symbols' Replace rather than swapping in one
frame, and a favorite bounces once as it is switched on, never off. Save's
fill and spinner move on the same curve when it is tapped; under Reduce Motion
all of it changes at once.

Native toolbar and menu actions retain the platform's sizing and background.
Toolbar Save still reserves its label while loading. Apple and Google sign-in
retain their provider styling. Dark cooking controls retain their legible
contrast and larger practical targets. These are contextual exceptions, not
alternative styles for ordinary filled actions.

## Motion and feedback

Keep the native iOS motion language. Shared control presses use a 0.94 scale
and a 150 ms zero-extra-bounce spring; cards and filled actions use 0.97 and
180 ms. Disabled controls do not scale. Reduce Motion removes press scaling
and explicit transition or scroll animation, while retaining immediate color,
label and completion feedback. Native navigation and scroll physics remain
system-owned.

Animation belongs to the view that reads Reduce Motion, never the save model.
Discover's return-to-top, cooking step navigation, recipe review guidance and
saved-detail transition all honor that setting. The existing durations remain
for ordinary motion; there is no new page entrance choreography.

Favorites and tab selection use selection feedback. Completing an ingredient
or step, reviewing an import, and finishing a timer use success feedback only
on the meaningful forward transition; undo and repeated states do not replay
success. Timer start/pause and navigation keep the existing feedback policy.
Saving shows its progress and landed state. Routine background loading must
not introduce animated movement of the page.

Routine sync and refresh draw no indicator at all — not on Recipes, Discover
or Inbox, and not over Watch. The strip under a navigation bar is reserved for
what needs the cook: a failed sync, recipe changes to review, a failed library
reload, a failed Discover refresh, and the "New recipes" pill, which is an
offer rather than a status. Nothing appears there or leaves because work is
merely in flight, so loading never moves the title, the controls, the feed or
the scroll position. A pull shows the system refresh control and nothing else.
Profile's Sync row is where routine sync state is read. A strip's fill runs
out to the sides of the screen and never upward: painted under the clear
navigation bar, it covers the large title.

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
- Recipe detail remains a pushed destination. Opened from a card — Recipes'
  grid, gallery or list artwork, a Discover row or shelf card — it zooms out of
  that artwork and back into it on Back or a drag down. A Discover recipe
  saved on its page has left the feed by the time the cook goes back, so that
  page zooms back to the centre of the screen rather than into a card. Watch,
  whose source is the whole screen, Reduce Motion, and a page no card opened
  (a notification, an import, a review) keep the ordinary push. Import and
  account flows remain native sheets.
- Recipe detail opens on a compact header, not a hero: a 96-point thumbnail
  beside the title and byline, the description beneath. The cook chose the
  recipe from that photo a moment ago, so time, servings and nutrition are
  whole on the first screen instead. At accessibility text sizes the thumbnail
  sits above the title. Missing or late artwork keeps the same square.
- A recipe whose link a platform player accepts offers the video from that
  header twice: the thumbnail wears a play badge and opens the player, and a
  tertiary "Watch original" link sits under the byline, because a badge on a
  photo is not a label. Both are absent — never disabled — when there is no
  playable video, and both work on a Discover preview, which has no options
  menu. The menu keeps its own entry under the same condition.
- Related steps stay in one sheet: Profile → Sign in, Nutrition → Apple Health,
  and failed import → correction notes, pasted details, or manual recovery.
  Back returns to the previous step.
- Recipe editor sections open at the top when selected. Cancel or a sheet swipe
  with unsaved edits shows Keep Editing and Discard Changes. The same protection
  covers manual recipe entry and all recovery forms; unchanged forms close
  immediately. Recovery Back also protects changes.
- Servings are adjusted in place on the metadata band, never in a sheet. The
  band stays two even cells; the right one reads, top to bottom, the people
  glyph, the count between a round minus and plus with nothing else on that
  line, and the word "servings". The circles are 30 points of `Surface.badge`
  on 44-point targets and disable at the ends of the range. After a change the
  last line reads "servings · Reset"; it keeps its height, and Reset's target
  grows down into the band's padding, never up into the plus. A change of
  count, Reset included, rolls the count and every ingredient amount up for
  more and down for fewer, and a row's "Not scaled" fades with them; under
  Reduce Motion they change at once. VoiceOver meets the stepper as one
  adjustable element. A band with nothing to scale — the reimport sheet, a
  recipe claiming no yield — keeps the read-only yield cell, and at
  accessibility text sizes the two cells stack.
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
- At accessibility text sizes, Watch stacks its action buttons vertically and
  lets its recipe panel scroll over a dark legibility background. Both Save
  and View recipe, or Open recipe and Start cooking, retain full-width targets.
- Do not reproduce recipe detail inside segmented card panels.
- Inbox is a plain native list. Empty copy is one short sentence. Recovery and
  review actions remain explicit when an import needs attention.

## Estimates

- An estimated value carries one short hedge, on the value: "About 45 min",
  "≈ 560" on calories and nothing else, "servings, estimated" under the count.
  No accent, no badge, and no sentence beside it.
- The reasons live once, in "About these estimates": a quiet metadata row
  under the nutrition card — under the band when there is no nutrition —
  collapsed by default and absent when there is nothing to list. It gives the
  time and servings reasons, each ingredient whose nutrition amount had to be
  assumed, by name, and says that nutrition is calculated from the ingredient
  amounts. It is a button whose value reads "Expanded" or "Collapsed", and it
  opens without animation under Reduce Motion.
- A note stays on an ingredient or a step only when it changes how that line
  should be read — the line itself is in doubt, or the totals left the
  ingredient out ("Not counted") — and then in `Label.secondary`, like "Not
  scaled". `FieldUncertainty.isRoutineEstimate` draws the line, by field.
- "Partial" stays on the nutrition card, neutral: a total that is short reads
  differently from one that is estimated. The review notice is unchanged — it
  is a task, not an estimate.

## Cooking

- Recipe detail's ingredient rows lead with a 40-point watercolour of the
  ingredient — the one place in the app where illustration is allowed, and
  the exception PRODUCT.md's anti-references now name. The square is the same
  40 points whether it holds a painting, a pantry container, or the
  `Surface.badge` disc with a neutral `fork.knife` that stands in where the
  set has no honest answer, so no row changes height for want of a picture
  and `dividerInset(iconWidth:)` keeps the divider on the label. The paintings
  sit on the porcelain ground bare in both appearances; the set's README warns
  against dark grounds, but composited onto `porcelain` at #101214 none of
  them loses its edges, and a disc behind every one reads heavier than the
  list wants. The art is decorative — `.accessibilityHidden(true)` — and never the only
  thing carrying a row's meaning. The reimport sheet reuses this list without
  the icons, because there the reader is comparing two versions of the text.
- Full Recipe stays a light checklist and overview.
- Focus Mode uses the graphite ground with porcelain text and a fixed signal-red
  progress/action color.
- One instruction owns the screen. Timers are large and stateful.
- Under them, "For this step" lists the ingredients linked to the current
  step, one row each: the amount, semibold, in a fixed leading column and the
  name beside it, at 20 points through `ladleScaledFont` — `title3`'s size and
  scaling in the two weights a row needs. Amounts follow the serving count
  chosen before cooking and come from Full Recipe's formatter, so a row with
  no amount is its name alone. The app never splits an amount between steps:
  an ingredient other steps also use shows the whole-recipe amount and says
  so under its name — "Recipe total. Also used in step 4."
- The "For this step" header is a small disclosure on a 44-point target.
  Folded, the section is the single line of names; it stays how the cook left
  it until cooking ends and is not stored. At accessibility sizes the amount
  sits above the name. The list scrolls beneath the pinned step controls.
- Food photography and library navigation do not appear in Focus Mode.

## Nutrition

- The nutrition sheet is per serving throughout. The calorie hero leads, and
  calories are the only figure that carries the "≈" marker.
- Under the total, a "Calories from" bar splits the calories the app can
  attribute — protein and carbohydrate at 4 kcal a gram, fat at 9 — into three
  segments. The macro tiles beneath are its legend: a segment wears its tile's
  dot colour, in the tiles' order, and each tile prints its own kcal and
  whole-percent share. That line is a value, so it is `metadata` in
  `Label.primary`. The shares are of the macro sum and always add to 100. The
  bar is hidden from VoiceOver because the tiles speak the same figures.
- The marks are protein `Mark.protein`, carbohydrates `Label.secondary` and fat
  `Label.primary`. Each has to read as a segment on the steel hero and as a
  dot on a raised tile, so all three hold 3:1 on both surfaces in light and in
  dark.
- An unavailable value is never drawn as zero. With any macro missing, or no
  usable serving basis, there is no bar, no kcal line and no note; without
  calories the bar stays and only the comparison is dropped.
- The macro sum is never reconciled with the stated calories. When the two
  whole numbers differ, one quiet line under the tiles states both and gives
  no reason, and neither number moves to meet the other. See the
  [macro calorie breakdown](docs/verification/2026-09-17-macro-calorie-breakdown.md).

## First run and Share Extension

- Welcome is a dedicated graphite surface with the installed app mark, one
  product sentence, and Apple, Google, and guest choices.
- State the ten-recipe guest limit because it changes the user's decision; avoid
  a passive feature tour.
- The Share Extension mirrors the porcelain/graphite palette and says only what
  is needed to confirm saving or explain recovery.
- When the save lands, the one status circle turns from steel to accent, its
  checkmark draws on and a single success haptic plays. A failure only fades
  its mark in; Reduce Motion shows either state at once.
- Recipe processing remains owned by the app when its sheet is dismissed. Close
  and Keep browsing return to the library without cancelling the durable job.

## Discover and account

- Discover ranks public recipe-video sources by aggregate saves and shows the
  creator account, source, image, summary, and save count. Tapping a result opens
  the complete shared extraction as a read-only recipe preview. Saving clones
  that already-resolved extraction into the current account. Neither action
  resubmits the video to the import, transcription, or model pipeline.
- Shelves break up that ranked list, because Discover is the launch screen
  and a list ordered by saves only turns over when someone saves something.
  Two of them are curated rails. **New to Overeasy** is ordered by when a
  source arrived here, not when its creator published it. **Quick dinners**
  keeps the sources a saver timed at thirty minutes or less; a source nobody
  timed is left out rather than assumed quick. Each rail is one short page of
  the same feed under a caption that says what its ordering promises — no
  "See all", no destination of its own, because neither ordering is something
  the app can ask for a second time.
- **Keyword shelves** are composed by the server from the keywords the recipes
  carry rather than from a list anybody maintains: the keywords with enough
  sources behind them, best-stocked first, titled in words a cook uses ("One
  pot", "Weeknight", "High protein") and never in a raw tag. A keyword shelf
  has no caption — its title says what is on it — and it is the one shelf
  with a **See all**, because a keyword is a filter: it puts that keyword in
  the filter every tab reads, keeps the diet and cuisine the shelf was
  composed under, and the ranked list becomes the rest of the row. The shelf
  then hides itself rather than repeating the list it just opened.
- **Two shelves lead and the rest are in the scroll.** Exactly two sit above
  the list, which is headed "All recipes", so the ranked rows start on the
  first screen however many shelves the corpus earns. Which two is drawn at
  random once per launch, from the rails and the keyword shelves alike, and
  then held the way Watch holds its order: a pull, a tab switch, a filter
  that leaves a shelf standing and the "New recipes" page never reshuffle
  under the cook, and a relaunch draws again. When a lead is empty, filtered
  out, under three cards or failed to load, the next shelf in that order takes
  its slot, and one shelf leads when only one can. Every other shelf goes into
  the list in the same order, one after every third row, between two hairlines
  so the rows after it do not read as the shelf's. A slot never moves as pages
  arrive, and a shelf the list ends before reaching follows the last row
  rather than becoming unreachable. Demo and UI-test runs draw nothing: the
  shelves stay as fetched, so the two rails lead.
- Every shelf is composed under the cook's filter, so a vegetarian is offered
  vegetarian shelves rather than vegetarian cards under a title chosen for
  somebody else — and a keyword with too little behind it once the diet
  applies has no shelf at all.
- A shelf is decoration on the feed, so it fails quietly: a shelf that
  does not load is absent rather than an error, and a shelf with fewer than
  three cards is dropped instead of drawn short. Searching hides them all
  outright, because search replaces the feed and unsearched cards beside the
  results would read as results.
- Scrolling back to the top of Discover fetches a fresh page 1 quietly and, if
  it differs from what is on screen, offers it as a "New recipes" pill in the
  same bar a failed refresh uses — the list only moves when the cook taps it,
  because scrolling up is how someone returns to a row they meant to keep.
- Discover excludes sources already saved by the current account and removes a
  row as soon as its direct save completes.
- Recipe cards and Discover results use the native long-press context menu as
  the modern replacement for 3D Touch. The menu previews the recipe and exposes
  Open plus a non-destructive Save or Favorite action.
- **Engagement and ratings.** Three numbers, each in words that say what it
  counts and whose count it is. *Likes* are the source platform's, read when
  the video was imported, so they ride on the recipe header's source line —
  "@thecopperpan · TikTok · 12K likes" — and lead a Discover row only under
  Most liked, the one order ranked by them. *Stars* and *saves* are
  Overeasy's and take their own metadata line beneath: "★ 4.6 (12) · Saved by
  18 cooks", the star and the average in `Label.primary`, the rest in
  `Label.secondary`. Stars appear only when the server publishes an average —
  it withholds one until three cooks have rated — and the count in brackets
  only ever follows stars. Where the line does not fit — a Discover row's
  column beside Save, or a large text size — the stars sit over the saves
  rather than the run breaking mid-phrase. A number nobody knows is absent:
  never a zero, never a dash, never a placeholder, and a header without the
  line closes up as if it had never been there. `EngagementText` holds the
  words and `EngagementLine` draws them for the header, Discover's rows and
  Watch alike; shelf cards stay count-free.
- A cook rates a recipe they have **saved**, on its page: a card near the end,
  above Start cooking, titled "Rate this recipe", with five `feature` stars on
  44-point targets — `hero` stars at accessibility sizes, where the stars are
  the control and 28 points reads as small print — over "Counts toward the
  average other cooks see." Rated, the title reads "Your rating", the chosen
  stars fill in the accent, and "Clear rating" takes the caption's line, so
  the card keeps its height. Stars fill at once, with selection feedback; a
  write that fails puts the previous stars back over one quiet line.
  VoiceOver meets the stars as one adjustable element. The card is never on
  a Discover preview (the cook has not saved it), never on a recipe typed in
  by hand (it has no source), and never before the server has answered for
  this cook: a server without ratings, or a failed request, leaves the page
  exactly as it was, with no error to read. There are no written reviews.
- Profile opens on the cook: a 96-point avatar — the provider's photo or a
  monogram, whichever they choose — the editable display name, the account
  kind, and one line of facts ("6 recipes · 2 favorites · cooking since
  August 2026"). A guest sees the word "Guest", what is on this device, and a
  sign-in button. Beneath that header sit accent color, saved-recipe count,
  and sync state, as rows under section headers with no explanatory footers.
  The app icons are one row that scrolls sideways and ends on half a tile; the
  installed icon wears the accent ring and a checkmark leads its caption, the
  row becomes a standard list at accessibility sizes, and a choice moves
  neither the form nor the row.
  Internal installation identifiers stay hidden.
- A new Apple or Google account is asked its name once, on a full screen
  between the welcome and the walkthrough, with the keyboard already up. Skip
  always works and a failed save never blocks entry. Guests are not asked.
- Every new cook, guests included, is asked about a diet once, on the screen
  after the name and in the same register: five diets, multi-select, and
  "No, I eat everything" selected on arrival. Skip always works and the
  question is never asked twice. Afterwards the diet is changed in one place
  only — under the name in the Profile header — and the filter menu can only
  put it down for the launch.

Provider sign-in controls share custom white buttons with black labels. Apple
uses the unmodified vector logo from Apple Design Resources, including its
padding. Its type is 43% of button height, with at least 8% trailing clearance.
Buttons grow with Dynamic Type as width permits while preserving these brand
proportions and the full provider name; they remain at least 44 points tall.
The system Apple control continues to handle authorization and accessibility.
Failure text can grow and scroll instead of being clipped into a fixed slot.
See the [HIG fixes and artwork attribution](docs/verification/2026-09-08-hig-fixes.md).

## Accessibility and verification

- Test default, extra-large, and accessibility Dynamic Type sizes.
- Verify light and dark cooking surfaces and VoiceOver labels.
- Verify 44-point targets and WCAG AA contrast for small text.
- Capture Recipes, Discover, Watch, Inbox, Profile, recipe detail, Focus Mode,
  welcome, and Share Extension at the project simulator size before a design
  checkpoint.
