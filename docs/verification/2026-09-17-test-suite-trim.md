# App test-suite trim

Covers `LadleUITests/`, `LadleTests/` and `Packages/LadleCore/Tests/`. The
backend suite was trimmed separately on the same day and is not described
here.

## The instruction

The owner, on September 17, 2026:

> need you to cut down the test suite as much as possible. especially the ui
> tests bc they never fail just add so much engineering time.

His standing rule for a test is that it protects meaningful behaviour, a
likely regression, an important edge case or a contract — and that it is not
a tautology, a trivial implementation detail, a low-signal snapshot,
duplicated coverage, UI wording, a copied config or token value, the text of
a source file, or an arbitrary count.

Two facts make that sharper for the app. No app test runs in CI — the only
workflow gates the backend — so an app test costs an engineer or an agent
time on every change and stops nothing automatically. And every UI test is a
full app launch: the eight that remain take 8 to 37 seconds each.

## What changed

| Suite | Before | After |
| --- | --- | --- |
| `LadleUITests` | 49 tests in 6 files | 8 tests in 1 file |
| `LadleTests` | 598 tests (1 intentional skip) | 522 tests (1 intentional skip) |
| `LadleCore` | 95 tests | 90 tests |

The unit work started from a read-only audit made earlier the same day
against `0a0553b`. Every candidate was found again by name and re-read
against the code it exercises before it was removed; nothing was removed on
the audit's word alone.

| Group | What went | Tests |
| --- | --- | --- |
| Token literals | `brickHex == "#C23B26"`, `Spacing.regular == 16`, corner, icon-size and press-timing values | 6 |
| Source text, counts, vacuous scans | tests that read a `.swift` file for a string, counted occurrences of one, or scanned for a token that exists nowhere | 8 |
| Copied project config | signing team, the Share scheme, the launch-screen colour name, the release host | 4 |
| Copy-only | account titles, sync values, recovery messages, conflict-review titles, Inbox labels, the brand name, an accessibility label | 7 |
| Getters, defaults, tautologies | info-dictionary passthroughs, `a + b`, a test that could not fail, a test of the test harness, constructor defaults | 19 |
| Same-branch rows | a second input down a branch a surviving test already walks | 20 |
| Demo scaffolding | the scenario-name table, the preferences-reset launch argument, one demo import slug | 3 |
| **`LadleTests` from the audit** | | **67** |
| Second pass over the five largest files | see below | 9 |
| **`LadleTests` in all** | | **76** |
| **LadleCore**: construct-and-read-back, raw values | three model read-backs; two `rawValue` literals that `Contracts/Fixtures/import-failures.json` already decodes | **5** |
| **`LadleUITests`** | everything but the smoke set below | **41** |

Nineteen `*Hex` string constants in `Ladle/Design/LadleTheme.swift` went with
the two tests that were their only readers. Colours render from the asset
catalogue; the strings were a second copy of it that nothing drew from.

Twenty more tests kept their place and lost their literals: they now assert
the behaviour and not the copy, count or token value beside it. Examples: the
control-height test asserts that no named height falls under the platform's
44-point hit target, rather than `44`, `48` and `52`; the retry-eligibility
test asserts that the button's title changes when the retry time arrives,
rather than the words; the ingredient-icon test asserts that every catalogue
slug has art in the bundle, rather than that there are 469 of them; the
guest-limit test keeps the two counts that prove a guest session answers with
`GuestPolicy`, and leaves the thresholds to LadleCore, which owns them.

### The second pass

One more pass over `ImportCoordinatorTests`, `DiscoverViewModelTests`,
`LibraryViewModelTests`, `AccountSessionTests` and `DesignTokenTests`, under
"as much as possible". It is small on purpose: a test went only where a named
surviving test walks the same branch and makes the same assertions, or where
the test could not fail.

- `ImportCoordinatorTests`
  - `testRelaunchMidInboxRetryReleasesTheResumedOutcome`: its assertions are
    a strict subset of `testReimportCancelledDuringResumeReleasesWithoutAnySheet`,
    on the same fake. Its row differs only in a retry history that
    `resumePendingImports` never reads.
  - `testConfirmedCancellationTerminatesRemoteAndRemovesDurableJob`: the same
    fake and the same three assertions as `testSecondCancelOfTheSameJobIsANoOp`,
    which cancels twice and still expects one remote cancel.
- `DiscoverViewModelTests`
  - `testLoadMoreAdvancesTheCursorRatherThanRefetchingPageOne`: its cursors
    `[0, 2]` are the start of `[0, 2, 0]` in
    `testSearchRestartsPagingAndAsksTheServer`, from the same setup.
  - `testAQuietRefreshMatchingTheFeedIsDiscarded`: the same guard arm as
    `testAQuietRefreshComparesAgainstTheFirstPageOnScreen`, which is the harder
    input; its request count is in `testAQuietRefreshRunsAtMostOnceAMinute`
    and its untouched state in `testAQuietRefreshNeverShowsTheRefreshingBanner`.
  - `testChangingTheFilterStartsANewFirstPage`: it called `load()` itself, so
    "another request" and "cursor 0" could not fail, and the filter riding the
    request is `testTheFilterRidesOnEveryFetchIncludingTheShelvesAndTheNextPage`.
- `LibraryViewModelTests`
  - `testCollectionRowsExposeApprovedOrderAndPresentation`: a copy of the
    production array literal — titles, symbol names, identifiers. The counts
    and their order are in `testHomeGroupsExposeUsefulRecipeReentryPoints` and
    `testTheSharedTagFilterNarrowsTheLibraryLocally`.
  - `testRemovingMaximumTimeKeepsOtherQueryState`: a one-line remove that
    `LibraryFilterTests/testRemovingAPillAndResettingClearTheRightState`
    reaches through the time pill, with a sibling filter surviving.
  - `testLargeLibraryRemainsDeterministicAcrossCorePresentations`: a thousand
    generated recipes through branches the small tests already walk, asserting
    counts (510, 100, 750, 666, 51) that restate the generator's arithmetic.
    It timed nothing and its titles were unique, so it proved neither speed
    nor tie-breaking.
- `AccountSessionTests`
  - `testOnboardingCompleteArgumentSkipsTheNameStep`: it passed with the code
    under test removed — a fresh store has nothing pending to skip. Every smoke
    journey launches with that argument.
- `DesignTokenTests`: nothing further.

Looked at and left: two more re-import presentation tests and the guest-cap
sign-in test in `ImportCoordinatorTests`; the no-shelves test and today's
two-shelves test in `DiscoverViewModelTests`;
`testDenseArchiveFactsScaleNutritionPerServing`; and in `AccountSessionTests`
the Apple name-step resume and the account without a profile. Each reaches a
branch a survivor also reaches, but each would lose something small — an
ordering, a direct equality on the operation, the Apple entry point, the only
test that flips one flag alone — and they sit in import recovery, nutrition
maths or session handling.

## The smoke set

`LadleUITests/SmokeUITests.swift`, one class, one launch helper. Each journey
is a path that only a running app can prove, and none of them asserts copy,
frames or screenshots.

| Journey | Why it stays |
| --- | --- |
| `testPrimaryJourneyCapturesInboxDetailAndCooking` | Launch lands on Discover, then Inbox, Recipes, a recipe, cooking and Focus. The spine of the app: the tabs, the navigation stack and the cooking cover, none of which exists outside the running app. |
| `testDiscoverRecipeSupportsTapAndLongPress` | A long press on a feed row raises the context menu, and View Recipe pushes the read-only preview with its Save. A row button, its own Save and a context menu share one row, and only a real press says which of them wins. |
| `testChangingTheYieldRewritesTheIngredientAmounts` | The inline servings control rewrites the ingredient rows. The maths is unit-tested; that the stepper is wired to the rows on screen is not. |
| `testTheLastIconInTheRowCanBeReachedAndChosen` | The icon row scrolls sideways and the switch goes through the real `setAlternateIconName` and SpringBoard's notice. No fake reaches either. |
| `testOfflineContentScenarioPreservesRecipes` | A failed sync keeps the saved library on screen and shows the failure strip. No unit test wires a sync transport failure to a library that still has its recipes. |
| `testReviewedImportLeavesTheInbox` | Add by link, the needs-review outcome, the Inbox row, review, and the row clearing (#91) — the whole import journey through the demo service. |
| `testNameStepArrivesPrefilledAndContinueLandsInTheLibrary` | First run with an account: the name step arrives filled in and Continue lands in the library. The prefill and the enable rule live in the view. |
| `testWatchDefaultsToInlinePlayerWithPlaybackControls` | Watch comes up with a player whose controls respond, and the video never hands the cook to Safari. |

Measured on a fresh iPhone 17 Pro simulator (iOS 26.5): the eight journeys ran
in 142 s, and 178 s by the wall clock for both app bundles together, build
included (156 s on the first run of the set). The 49-test bundle was not run
before the cut. The two most recent measured full runs on record are 26 tests
in 350 s (September 2) and 27 tests in 374 s (September 7), about 13.7 s a
test, which puts 49 tests at roughly eleven minutes before the longer tests
added since are counted.

`testDiscoverFailureOnLaunchFallsBackToRecipes` was considered as a ninth and
not kept. The rule — once per process, only from Discover's root, never after
the cook has picked a tab, and silent — is `DiscoverLaunchFallback`, and five
tests in `LibraryNavigationStateTests` cover every branch of it;
`DiscoverViewModelTests/testInitialLoadOffersRetryWhenDiscoveryFails` pins
that a failed first load is `.failed`. What has no test is the two SwiftUI
hops between them: `DiscoverView.reportInitialLoad` calling
`onInitialLoadFailed`, and `LibraryView.fallBackToRecipesIfNeeded` selecting
Recipes.

## Deliberately kept

- The whole-tree convention lints in `DesignTokenTests` (semantic colour
  roles, control tints, named control heights, named icon sizes, and the
  accent's two storage readers). They read source, which the rule otherwise
  excludes, but they are what holds agent-written screens to the design
  tokens, and the accent one guards a shipped bug.
- The seven SwiftUI wiring pins: four in `ImportCoordinatorTests` for the
  re-import sheet's release, attach and paired presentation and the failed
  sheet's cancelled branch; `NotificationServiceTests` for the claiming
  resolver; `RemoteImageCacheTests` for the hero image's owner;
  `CookingViewModelTests` for timer feedback inside the `TimelineView`. Each
  guards a shipped regression in view code, and no behavioural test reaches
  any of them — the composed tests beside them cover the coordinator, not the
  call site. One lost a second assertion that only matched wording.
- Everything in auth, session and token handling, import recovery and retry,
  sync conflict handling, the SwiftData repository, wire-contract decoding and
  the golden fixtures, scaling and ingredient formatting, nutrition maths and
  accessibility contrast, apart from rows shown above to walk a branch a named
  surviving test already walks.
- The app-side demo scenarios and launch arguments, including those only the
  deleted UI tests used. They drive manual UI review and captures.

## No longer covered automatically

UI behaviour with no unit-level equivalent, accepted under the instruction:

- **Largest-text layout** — Watch actions stacking, the custom and welcome
  sign-in buttons fitting, Discover's Save fitting horizontally, the one-column
  grid at XXXL, the welcome screen's guest button at AX XXXL. The fixes are
  recorded with captures in `2026-09-08-hig-fixes.md`. Still unit-tested:
  `WelcomeView.usesScrollingLayout`, and Discover Save's height and stable
  bounds at three text sizes.
- **Sheet navigation and discard confirmations** — sign-in pushed inside the
  Profile sheet, Apple Health inside the nutrition sheet, recovery modes using
  Back, the editor's and manual entry's Keep Editing / Discard Changes, the
  editor section starting at its heading. The model-level discard is
  unit-tested; no dirty-state predicate is.
- **The filter control end to end** — the time submenu and its pill, a diet
  from onboarding reaching every tab, pausing a diet, the ingredient alert from
  Discover's toolbar and from Watch's overlay. The filter store, the library
  narrowing, the pills and the Discover request parameters are unit-tested;
  the menus, the alert and the "N recipes" count are not.
- **Profile** — the signed-in and guest headers, the avatar menu's
  composition, the first section's spacing, the retired footers, the diet row,
  and the empty name step's disabled Continue and its Skip.
- **State scenarios on screen** — offline with an empty library, the store
  failure screen, Discover's empty state, the launch fallback's view glue, the
  import quota and rate-limit sheets, the expired-session strip, the 80-recipe
  library. The states behind them are unit-tested.
- **Discover and import odds and ends** — See all on a keyword shelf, closing
  the processing sheet while an import continues, the recovery labels' shared
  edge, recovering a missing-instructions import from the Inbox, Delete in the
  recipe options menu, the accent picker and the grid/list switch.

Riders removed from the journeys that stayed, each a few lines to restore:

- Discover: saving in place from the preview, and the tab keeping its stack
  across a trip to Recipes (#88). `DiscoverSaveModel`'s flip from preview to
  saved is unit-tested; per-tab stacks are not.
- Scaling: time, servings and nutrition fitting the first screen (#151), and
  Reset returning the as-written amounts and leaving (#148). The model's
  `reset()` is unit-tested.
- Watch: the full-screen frame, mute, paging to the next video, switching
  between the Discover and My Recipes feeds, no account button. None has a
  unit test; the feed and mute are private view state.
- Name step: the heading, the Skip button's presence and the keyboard being
  up on arrival.
- Icon: the 44-point tile frame. The launch also stopped pinning an avatar
  URL, which was a network fetch in every run.
- Every screenshot attachment.

Unit level, by design: token values, project config strings and UI copy are
not asserted anywhere now, and the demo scenario names are exercised only by
whoever launches them.

## Verification

On a simulator created for this work and deleted after it (iPhone 17 Pro,
iOS 26.5), scheme `LadleAllTests`, on the branch's final code:

- `swift test --package-path Packages/LadleCore`: 90 tests in 12 suites
  passed.
- `xcodebuild test … -only-testing:LadleTests -only-testing:LadleUITests`, one
  invocation: `LadleTests` executed 522 tests, with 1 test skipped and 0
  failures, in 10.5 s; `LadleUITests` executed 8 tests, with 0 failures, in
  141.9 s. `** TEST SUCCEEDED **`. The skip is the live App Attest test, as
  before.
- The unit bundle was also run after each group of removals, before that
  group was committed: 592, 573, 531 (twice, the second after the assertion
  fixes) and 522 tests, each with 0 failures.
- The final build prints no compiler warning. One surfaced on the way — a
  main-actor property read inside an autoclosure, in the icon test's helper,
  moved as it was from `ProfileSheetUITests` — and was fixed. No private
  helper in a trimmed file is left without a caller.
- `Ladle.xcodeproj` was regenerated with `xcodegen` for the UI files; its diff
  is those file references and nothing else.

## Appendix: every deleted UI test

What still asserts the behaviour at unit level, and what nothing does. "None"
means accepted under the instruction. The files are in `git show d27f16b`.

`StateScenarioUITests`

| Test | Unit coverage | Not covered |
| --- | --- | --- |
| `testOfflineEmptyScenarioExplainsBothStates` | `SyncStatusTests/testFailureClassifiesOfflineAndPreservesLastSuccess` | the empty library state, and the two together |
| `testInitialStoreFailureScenario` | `AppBootstrapTests/testLocalStoreFailureProducesRecoverableDiagnostic`, `testRetryCanRecoverAfterStoreCreationFailure` | the failure screen |
| `testDiscoverEmptyScenario` | none | |
| `testDiscoverFailureOnLaunchFallsBackToRecipes` | five `DiscoverLaunchFallback` tests in `LibraryNavigationStateTests`; `DiscoverViewModelTests/testInitialLoadOffersRetryWhenDiscoveryFails` | the two SwiftUI hops between them |
| `testImportQuotaScenario` | `ImportCoordinatorTests/testCapacityErrorsKeepPreciseOperationStateAndSavedLink`, `testRetryEligibilityExplainsCapacityAuthAndManualRecovery` | the sheet |
| `testImportRateLimitedScenario` | the same two | the sheet |
| `testAuthenticationExpiredScenario` | `SyncStatusTests/testRateLimitAndAuthenticationHaveDistinctStates` | the strip on Recipes for this failure (the offline journey draws the same strip) |
| `testLargeLibraryScenario` | none beyond the ordinary library tests | |
| `testLargeLibraryAtXXXLargeUsesOneReadableColumn` | none | |
| `testWelcomeAtAccessibilitySizeRemainsReachable` | `ProjectSmokeTests/testWelcomeOnlyScrollsForAccessibilityTextSizes` | the guest button being reachable |
| `testEmptyLibraryAndInboxBothOfferAnImport` | none | |

`HIGRegressionUITests`

| Test | Unit coverage | Not covered |
| --- | --- | --- |
| `testEditorCancelOffersKeepEditingAndDiscard` | `RecipeEditorViewModelTests/testDiscardRestoresOriginalWithoutPersisting` | the confirmation, and Keep Editing keeping the draft |
| `testEditorSectionStartsAtItsHeading` | none | |
| `testProfileSignInUsesBackWithinOneSheet` | none | |
| `testEditorSwipeOffersDiscardAndKeepsTheDraft` | the same model-level discard | the interactive-dismiss interception |
| `testManualEntryOnlyConfirmsWhenThereAreChanges` | none | |
| `testRecoveryUsesBackAndProtectsAllThreeDrafts` | `ImportCoordinatorTests/testRetryStoresCorrectionNotesAndCanRecoverParserFailure`, `testPastedDetailsRecoverPrivateImportWithoutDiscardingLink` | Back, and the three drafts being protected |
| `testHealthExportReturnsToNutritionWithinTheSheet` | none | |
| `testWatchActionsStackAtLargestTextSize` | none | |
| `testCustomSignInButtonsFitAtLargestTextSize` | none | |
| `testWelcomeProviderButtonsFitAtLargestTextSize` | `testWelcomeOnlyScrollsForAccessibilityTextSizes`; `AccountSessionTests/testEveryNewCookIsAskedAboutADietOnceIncludingAGuest` | the buttons fitting |

`DiscoverInteractionUITests`

| Test | Unit coverage | Not covered |
| --- | --- | --- |
| `testDiscoverSaveFitsAtLargestTextSize` | `DesignTokenTests/testDiscoverSaveKeepsItsBoundsWhileLoadingAtEveryTextSize` | fitting the screen's width |
| `testProfileHeaderShowsTheSignedInCook` | `AccountSessionTests/testUITestingLaunchArgumentsPinTheProfile`; `ProfileFactsTests/testSignedInLineCountsRecipesFavoritesAndTheFirstMonth` | the provider line, and no sign-in button |
| `testProfileAccentAndRecipeViewPreferencesAreReachable` | `DesignTokenTests/testAccentPreferenceHasStableChoicesAndFallback`; `LibraryViewModelTests/testDisplayModePersistsAcrossViewModels` | the two menus, and equal grid row heights |
| `testRecipeProcessingSheetCanBeDismissedWhileImportContinues` | `ImportCoordinatorTests/testTaskTeardownDuringNetworkCallLeavesJobParsingInsteadOfFailed` | reaching it through the sheet's Close |
| `testFailedImportRecoveryActionsShareLabelOrigin` | none | |
| `testMissingInstructionsExplainsFailureAndRecoversFromInbox` | `ImportCoordinatorTests/testMissingRecipeInstructionsAsksForTextBeforeRetrying`, `testPastedDetailsRecoverPrivateImportWithoutDiscardingLink` | the Inbox row, and reopening recovery from it |
| `testRecipeOptionsExposeTheDeleteAction` | none | |
| `testSeeAllOnAKeywordShelfNarrowsTheListBeneathIt` | `RecipeFilterStoreTests/testSeeAllOnAShelfPutsItsKeywordInTheSharedFilter`; `DiscoverViewModelTests/testAShelfForAKeywordAlreadyBeingFilteredOnIsHidden` | the button in the shelf's header |

`ProfileSheetUITests`

| Test | Unit coverage | Not covered |
| --- | --- | --- |
| `testProfileOpensOnTheCookRatherThanOnEmptySpace` | none | |
| `testProfileHasNoExplanatoryFooters` | none | |
| `testGuestProfileOffersSignInAndCountsThisDevice` | `ProfileFactsTests/testGuestLineIsAboutThisDevice` | the guest placeholder and the sign-in button |
| `testAvatarMenuOffersAPhotoAndNoRemoveForAProvidersPicture` | `AccountSessionTests/testAvatarCustomLaunchArgumentSaysThePhotoIsTheCooks`; `AuthContractTests/testTokensWithoutTheCustomPhotoFlagDecodeAsTheProvidersPhoto` | the menu's composition |
| `testAvatarMenuRemovesOnlyThePhotoTheCookChose` | `AccountSessionTests/testAppliedProfileCarriesWhoseThePhotoIs`; `AuthContractTests/testTokenFixtureSaysThePhotoIsTheCooksOwn` | the menu's composition |
| `testTheDietIsChangedBesideTheNameAndTheLibraryFollows` | `AppIconStoreTests/testTheOfferIsMadeOnceToAVegetarianCook`, `testDecliningTheOfferLeavesTheEgg`; `LibraryViewModelTests/testTheSharedTagFilterNarrowsTheLibraryLocally` | the diet row in Profile |
| `testEmptyNameStepDisablesContinueUntilSomethingIsTyped` | none | |

`RecipesFilterMenuUITests`

| Test | Unit coverage | Not covered |
| --- | --- | --- |
| `testFilteringByTimeNarrowsTheLibraryAndThePillClearsIt` | `LibraryViewModelTests/testCookOnlyRecipeIsFilteredAndSortedOnItsCookTime`; `LibraryFilterTests/testRemovingAPillAndResettingClearTheRightState`, `testPillTitleMatchesThePickerRowForTheSameValue` | the submenu, and the recipe count in the header |
| `testADietChosenDuringOnboardingIsAlreadyOnEveryTab` | `DiscoverViewModelTests/testTheFilterRidesOnEveryFetchIncludingTheShelvesAndTheNextPage`, `testTheDemoFeedAnswersTheFilterTheWayTheServerWould`; `LibraryViewModelTests/testTheSharedTagFilterNarrowsTheLibraryLocally` | the onboarding step writing the diet |
| `testPausingTheDietShowsEverythingAndItIsBackNextLaunch` | `RecipeFilterStoreTests/testPausingTheDietHidesItFromTheFilterButKeepsIt`, `testAPausedDietIsBackOnTheNextLaunch`, `testChangingTheDietLiftsAPause` | the menu row, and Discover fetching again |
| `testAnIngredientTermIsTypedIntoTheControlAndNarrowsDiscover` | `DiscoverFilterRequestTests/testEveryFamilyTravelsAsItsOwnRepeatedParameter`; LadleCore `RecipeFilterTests` | the alert from a toolbar item |
| `testTheControlAndItsAlertAlsoWorkFromWatchsOverlay` | `RecipeFilterStoreTests/testClearingTheFiltersPausesTheDietRatherThanDeletingIt` | the control and its alert over the video |
