# Recipe detail zooms out of its card

Part of the motion-bridges pass. Opening a recipe was the standard push: the
card the cook tapped slid away with the rest of the screen, and the page
arrived from the side with nothing tying the two together. The page now
zooms out of the card's artwork and back into it, the iOS 18 zoom transition,
so the photo the cook chose is visibly the page they are reading.

## Purpose and behaviour

- **Recipes.** Tapping a grid card, a gallery tile or a list row opens the
  page out of that card's artwork. Back, the edge swipe and a drag down on
  the page all return it into the same artwork.
- **Discover.** A list row and a shelf card do the same. The detail fetch
  still runs first, with its veil on the card; the zoom starts when the page
  is pushed. A recipe saved on its page has left the feed by the time the
  cook goes back, so that page zooms back to the centre of the screen rather
  than into a card. A detail that lands after the cook has left Discover is
  pushed onto whichever tab they are on.
- **Unchanged push.** Watch keeps the push: its source is the whole screen,
  and a zoom out of a full-screen video is no zoom at all. So do Reduce Motion
  and every page no card opened — a tapped notification, a finished import,
  an Inbox review, a recovery sheet's "view recipe".
- **Still a pushed destination.** It is the same `NavigationStack` push with
  a different transition. The back button, the light impact on a push and
  the context menus are untouched.

## Decisions

- **The card is carried by the page, not derived from it.** A Discover
  preview's recipe id is its `sourceID` while the library's cards carry the
  saved recipe's id, and a notification or import pushes a recipe that may
  have a card on screen that did not open it. So each card hands up the id it
  is registered under, `LibraryRecipeDestination.zoomSource` keeps it, and a
  page opened any other way has none and pushes. It takes no part in the
  destination's equality, like the Discover save path beside it.
- **The id names the shelf.** Discover can draw one recipe in a shelf and in
  the list below it at once, and two sources under one id leave the zoom to
  pick either. `RecipeZoomID` is the recipe id plus the shelf, nil for a list
  row and for every Recipes card (the Recipes tab draws each recipe once).
- **One namespace per zooming stack.** Recipes and Discover each own a
  `@Namespace`, set on their `NavigationStack` as the `recipeZoomNamespace`
  environment value. The cards read it through `recipeZoomSource`, the page
  through `recipeZoomTransition`, and neither initializer grew a parameter.
  Where the value is absent — Watch, Inbox, SwiftUI previews, context-menu
  previews, which do not inherit custom environment values — both modifiers
  do nothing.
- **Decided as the page opens.** `LibraryTab.zoomSource(for:reduceMotion:)`
  is the rule: Recipes and Discover zoom from the card that opened the page,
  every other tab and Reduce Motion push. It runs when the page is pushed and
  its answer is stored, so the page returns the way it came. Deciding it
  while drawing would have let Reduce Motion, turned on with a page open,
  swap the transition modifier — a structural change that rebuilds the page
  and drops its state, including a Discover preview that has just become the
  saved copy.
- **A recipe saved on its page returns to the centre.** Discover drops a
  saved recipe from its list and shelves as the save lands, so going back
  finds no card and the zoom takes its own fallback. The page cannot switch to
  the push instead: the transition is settled as it opens, and swapping it
  would rebuild the page. Keeping the card until the page closes would change
  when a saved recipe leaves the feed — a product call for the owner, and one
  that would put a transition's needs into the save path.
- **A card zooms only onto its own stack.** Discover pushes its page once the
  detail arrives, which can be after the cook has switched tabs. The page then
  goes onto that tab's stack, where its card is not, so the library keeps
  Discover's card only while Discover is still selected and a late page
  pushes.
- **The source is the clipped artwork, with its own corner radius.** The zoom
  lands on the shape it left rather than a square corner. On Discover it sits
  beneath the loading veil, which has gone by the time the page opens.
- **No explicit animation.** The zoom is the system's; its timing and
  interruptibility are native, like the push it replaces.

## Affected components

- `Ladle/Library/LibraryView.swift` — `RecipeZoomID`, the
  `recipeZoomNamespace` environment entry, the `recipeZoomSource` and
  `recipeZoomTransition` modifiers, `LibraryTab.zoomSource(for:reduceMotion:)`,
  `LibraryRecipeDestination.zoomSource`, the per-stack namespaces, and the
  open paths that pass the card.
- `Ladle/Library/RecipeGridCard.swift` — grid and gallery artwork.
- `Ladle/Library/RecipeListRow.swift` — list thumbnail.
- `Ladle/Library/DiscoverView.swift` — `openRecipe` now carries the card;
  `DiscoverRecipeRow` and `DiscoverShelfCard` artwork.
- `LadleTests/LibraryNavigationStateTests.swift` — the rule.

## Verification

- Red first: the rule's tests in `LibraryNavigationStateTests` were written
  before `LibraryTab.zoomSource(for:reduceMotion:)` and `RecipeZoomID`
  existed, so the unit target could not compile. After review they are
  `testOnlyRecipesAndDiscoverOpenAPageByZoomingOutOfItsCard`, a table over
  every tab (Recipes and Discover zoom, Watch and Inbox push), and
  `testReduceMotionKeepsThePush`. The table test was typechecked against a
  stub of the rule with the XCTest overlay.
- The new SwiftUI surface (the `@Entry` optional namespace, the
  `matchedTransitionSource` clip-shape configuration and
  `.navigationTransition(.zoom(sourceID:in:))` behind a `ViewModifier`) was
  typechecked in isolation with `swiftc -typecheck -swift-version 6
  -strict-concurrency=complete -target arm64-apple-ios26.0` against the iOS
  27 SDK.
- `git diff --check` before committing.
- Pending at integration: the `LadleAllTests` unit run
  (`-only-testing:LadleTests/LibraryNavigationStateTests`, then the unit
  suite), a full Ladle and Share Extension build, and on-device checks of:
  each of the five sources opening and closing into its own artwork, by
  Back, the edge swipe and a drag down from the top of the page; the tab
  bar through the zoom; a
  recipe drawn in a lead shelf and in the list zooming from the one tapped;
  Reduce Motion and Watch pushing; saving a Discover preview (Save becoming
  the heart) and then going back, which should zoom to the centre of the
  screen; switching to Recipes while a Discover detail loads on a slow
  network, which should push; deleting a recipe from its page; and
  "Open Recipe" / "View Recipe" from a context menu.

### Captures

Added at integration.
