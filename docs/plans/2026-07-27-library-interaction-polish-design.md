# Library Interaction Polish Design

## Problem

Overeasy's Library Home currently has three related problems:

1. In the real app on **Overeasy - iPhone 16 Pro**, tapping the visible
   **Import inbox** card can open **Watch** instead. The existing UI test taps
   the semantic accessibility element and therefore does not cover the
   physical hit region that is failing.
2. The Collections rows read as unfinished bare text. Counts and chevrons are
   cramped against the trailing edge, the dividers do not create a clear
   group, and the rows do not carry the visual intent of the rest of Home.
3. Important actions have little tactile or motion response, so the app feels
   flatter than its warm visual identity suggests.

The existing uncommitted Library navigation work remains the correct basis:
successful review completion uses one typed navigation path, returns to the
remaining Import Inbox when actionable imports remain, and returns to Home
when the inbox becomes empty.

## Approved Direction

Use a tactile, directional interaction system rather than decorative
animation:

- Pressable cards and controls compress quickly and release cleanly.
- Collection expansion and grid/list changes reshape in place.
- Favorites and review completion use symbol/state transitions.
- Haptics are reserved for meaningful navigation, selection, completion,
  timer, and error events.
- Nothing loops, floats, pulses, or uses elastic overshoot.
- Reduce Motion removes scale and movement while retaining opacity and state
  clarity.

## Import Inbox Hit Region

The Import Inbox and Watch cards will each own an explicit rounded interaction
shape matching their visible bounds. The Watch card will be clipped to that
shape, and the Inbox card will sit above later siblings in hit-testing order.

A UI regression will tap the physical center coordinate of the rendered Inbox
card and assert that:

- `library.import-inbox.root` appears;
- `library.watch.root` does not appear; and
- returning Home allows the same physical tap to work again.

This complements rather than replaces the existing semantic accessibility
tests.

## Collections

Collections will become one grouped panel under the existing collapsible
header. Each 56-point row will include:

- a small tinted circular icon;
- the collection title;
- a quiet recipe count;
- a consistently aligned chevron; and
- an inset divider between rows.

The proposed symbols are:

- **Ready in 30 minutes:** `timer`
- **Favorited:** `heart.fill`
- **Haven't cooked yet:** `frying.pan`

The panel uses one subtle Oat/Field surface and one quiet outline. This gives
the section intention without turning every row into a separate card.

Implementation keeps the ordered row content in
`LibraryCollectionRowPresentation`, exposed by `LibraryViewModel`, so titles,
symbols, counts, destinations, identifiers, and divider placement have one
testable source. `LibraryHomeView` renders that source as the grouped panel.
The presentation test was observed failing before the model existed, then all
22 `LibraryViewModelTests` and a dedicated simulator build passed after the
panel was implemented. Dark appearance and accessibility Dynamic Type remain
part of the final Xcode-run manual checkpoint.

## Motion

Create one shared press style with two strengths:

- **Card:** scale to `0.97`, slight opacity change, 180 ms snappy return.
- **Control:** scale to `0.94`, slight opacity change, 150 ms snappy return.

Both use zero extra bounce. Primary buttons retain their existing prominence
but use the same timing language.

Section expansion uses a 220 ms opacity-and-upward transition. Existing
grid/list changes use the same zero-bounce snappy timing. Review completion
replaces the review action with a brief success state before the typed
navigation path resolves to the Inbox or Home.

Implementation centralizes the two strengths in `LadlePressKind` and
`LadlePressButtonStyle`, including disabled-state opacity and the Reduce Motion
scale fallback. It covers Home cards and thumbnails, collection and Library
controls, favorite controls, cooking completion/navigation controls, and
timer/reset controls. Primary buttons now share the card timing. The token
test was observed failing before the types existed; afterward all 27 focused
design, cooking, and project-smoke tests and a simulator build passed.

Review completion now persists first, replaces the action with a visible
checkmark and “Reviewed,” applies the returned recipe, and lets that state
remain for 160 ms before resolving the typed navigation path. Reduce Motion
uses a zero delay. A view-scoped SwiftUI task provides the delay and is
automatically cancelled if Recipe Detail disappears. The Import Inbox list
uses a 200 ms zero-bounce update, and the presentation/delay test plus all
three navigation-state tests protect the remaining-inbox and empty-inbox
routes.

## Haptics

Use SwiftUI sensory feedback tied to state changes:

- light impact when pushing a meaningful destination such as Import Inbox,
  Watch, a collection, or a recipe;
- selection feedback for Home/All, grid/list, filters, and favorites;
- success feedback for completed review, completed cooking steps, and finished
  timers;
- medium impact for starting or resuming a timer; and
- warning/error feedback only when an operation actually fails.

Do not add haptics to ordinary scrolling, back navigation, passive loading, or
every incidental tap.

Implementation routes conditional feedback through
`LadleFeedbackPolicy`: navigation only acknowledges path growth, completion
only acknowledges an incomplete-to-complete transition, and timer feedback
maps only start/resume, pause, and finish phase changes. Favorites publish
their state only after repository persistence succeeds, while real operation
errors use error feedback. Section, display-mode, filter, and persisted
favorite changes use selection feedback. The policy and persistence tests
were observed failing first and then passing after implementation; tactile
quality still requires the final physical-device follow-up.

## Accessibility

- Preserve at least 44-by-44-point interaction targets.
- Keep semantic labels and identifiers on the actual buttons.
- Use color together with symbols and text, never as the only state cue.
- Under Reduce Motion, disable scale, move, and symbol travel while keeping
  opacity changes and haptics.
- Verify the grouped Collections panel with accessibility Dynamic Type and
  dark appearance.

## Verification

- Per the subsequent user direction, the `LadleUITests` target and source suite
  have been removed. Physical hit-region, Dynamic Type, dark appearance,
  Reduce Motion, and interaction checks are now manual Xcode-run verification.
- Run the new physical-coordinate Inbox regression before and after the fix.
- Run the existing review-routing and reopen regressions.
- Run Library, Recipe Detail, and Cooking focused tests.
- Build for simulator with `xcodebuild`.
- Launch through Xcode on **Overeasy - iPhone 16 Pro**
  (`5CDD8E03-C52C-449A-8332-28F29FF937B7`) so the simulator app retains the
  entitlements required to reach the local API.
- Manually verify Inbox and Watch hit regions, Collections alignment, Reduce
  Motion, dark appearance, review completion, favorites, cooking steps, and
  timers.
