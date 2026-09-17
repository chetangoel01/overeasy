# Quiet sync and refresh

Issue [#140](https://github.com/chetangoel01/overeasy/issues/140). The owner
reported that the loading strip above Discover made the whole interface jump,
and supplied a
[capture](captures/2026-09-11-user-feedback/discover-sync-loading.jpg) of
"Syncing recipes…" over the placeholders, under a tall empty header.

## Purpose

Routine loading must never move the feed, the title, the controls or the
scroll position. Only something the cook has to act on may take space under a
navigation bar.

## Decision

On September 17, 2026 the owner chose to **hide routine sync entirely**: no
indicator at all for routine background sync or refresh. Failures and
conflicts that need attention are the only things shown. The other option
offered, a navigation-bar indicator, was declined. Profile's Sync row stays
the one place routine state can be read.

Watch's "Refreshing Discover" overlay cost no layout, so it never shifted
anything. Removing it was an engineering call for consistency with "no
indicator at all": returning to Watch refreshes its feed every time, which
made it the routine indicator shown most often.

## User-visible behaviour

- Recipes, Discover and Inbox no longer show "Syncing recipes…" while a sync
  runs at launch, on returning to the app, or after an edit or import.
- Discover no longer shows "Refreshing Discover…". A pull shows the system
  refresh control, as before, and the rows on screen stay until the new page
  replaces them.
- Watch no longer shows "Refreshing Discover" over the video.
- Unchanged: the failed-sync strip (offline, sign in again, try later), the
  conflict strip and Review, the library reload strip and Try Again,
  Discover's "Showing earlier Discover results" and Try Again, Watch's
  "Showing earlier results", the "New recipes" pill, and Profile's Sync row,
  which still reads "Syncing" during a sync.

## What moved the screen

`LibraryView.tabStack` puts its banners in a `.safeAreaInset(edge: .top)`
shared by Recipes, Discover and Inbox, and Discover has a second inset of its
own for the refresh bar. `SyncStatusBanner` drew a 36-point strip for
`.syncing` and `DiscoverRefreshBanner` drew one for `.refreshing`; both drew
nothing once the work finished. Each sync or refresh therefore opened the
inset and closed it again, pushing everything beneath it down and back up.

Both views now draw their failed state only. `SyncStatus` and
`DiscoverViewModel.RefreshState` are untouched: `.syncing` still feeds
Profile's row, and `.refreshing` still guards `load()`, `loadMore()` and
`refreshQuietly()` against overlapping requests.

## The empty header

The issue asked for a runtime reproduction before anything else was blamed
for the tall empty header. It reproduced, and it is a second, independent
defect: **any strip in the top inset hid the large title.**

Each strip set `.background(Surface.steel)`, and a SwiftUI background ignores
every safe-area edge unless told otherwise. A strip directly under the
navigation bar therefore painted up through the bar's region. On iOS 26 and
27 the bar is clear and the large title is drawn beneath that fill, so the
title vanished and the header read as an empty block of steel. Two earlier
records show it, unremarked:
[Recipes offline](captures/2026-09-08-ui-audit/110-scenario-offline-with-recipes.jpg)
has no "Recipes", and the
[New recipes pill](captures/2026-09-01-discover-refresh-at-top/01-new-recipes-pill.png)
has no "Discover".

The four strips — failed sync, conflicts, library reload, and Discover's bar,
which carries the failed refresh and the "New recipes" pill — now pass
`ignoresSafeAreaEdges: .horizontal`. The fill still reaches the sides of the
screen in landscape and no longer runs upward. Layout is untouched: every
strip sits exactly where it sat, and only the paint above it is gone.

Observed on private iPhone 17 Pro simulators, iOS 26.5 and iOS 27.0:

| State | Large title | Search field | First row |
| --- | --- | --- | --- |
| Loading, no strip | present | 26.5 shown, 27.0 collapsed | directly under the bar |
| Loaded, no strip | present | same as loading | where the first placeholder was |
| Under a strip, before | **hidden** | same as above | directly under the strip |
| Under a strip, after | present | same as above | unchanged |

So the placeholders already used the normal chrome, and nothing moves when
the feed replaces them: compare [loading](captures/2026-09-17-quiet-sync/04-discover-loading.jpg)
with [loaded](captures/2026-09-17-quiet-sync/05-discover-loaded.jpg). Nothing
was changed there. The search field missing from the owner's capture matches
iOS 27.0, where the navigation-bar drawer starts collapsed under
`displayMode: .automatic` whether or not a strip is up and whether or not the
feed has loaded; the same build on 26.5 shows it. The phone's iOS version was
not checked, so that part is an inference from the simulators.

[Before](captures/2026-09-17-quiet-sync/01-before-loading-under-strip-ios27.jpg)
reproduces the owner's capture on iOS 27.0 in dark mode, with the failed-sync
strip standing in for "Syncing recipes…", which shared its chrome.
[After](captures/2026-09-17-quiet-sync/02-after-loading-under-strip-ios27.jpg)
is the same state with the fix, and
[Recipes offline, after](captures/2026-09-17-quiet-sync/03-after-recipes-offline.jpg)
is the counterpart of the September 8 capture above.

Captures 01, 02, 04 and 05 needed the placeholders to stay up, and the demo
feed loads at once. They were taken with a temporary eight-second
`Task.sleep` at the top of `DemoDiscoverService.fetchDiscoverPage`, which is
not in the branch. 03 is the screenshot
`testOfflineContentScenarioPreservesRecipes` attaches. Landscape was checked
with a temporary rotation in that UI test, also not kept: the strip still
spans the screen edge to edge.

## Affected components

- `Ladle/Library/LibraryView.swift` — `SyncStatusBanner` draws `.failed` only;
  its single-use `banner` helper folded into the body.
- `Ladle/Library/DiscoverView.swift` — `DiscoverRefreshBanner` draws `.failed`
  only; `DiscoverTopBar.systemImage` is no longer optional, because the
  spinner strip was the only caller without an icon.
- `Ladle/Library/WatchView.swift` — `discoverRefreshOverlay` draws `.failed`
  only.
- `SyncStatusBanner`, `LibraryReloadErrorBanner`, `DiscoverTopBar` and
  `Ladle/Sync/SyncConflictReviewView.swift`'s `SyncConflictBanner` — the fill
  no longer ignores the top safe area.
- `LadleTests/DesignTokenTests.swift` —
  `testRoutineSyncAndRefreshTakeNoSpaceButFailuresDo`.
- `DESIGN.md` — the rule, under Motion and feedback.

No file was added or removed, so the generated project is unchanged.

## Verification

`testRoutineSyncAndRefreshTakeNoSpaceButFailuresDo` hosts both strips and
measures them. Before the change it failed twice — `.syncing` and
`.refreshing` each measured 36.3 points — and it passes now, with the failed
states still taking space. An empty root measures zero in the same harness,
so the zero is a real measurement. No view is drawn for a routine state, so
the result does not depend on text size. Strings are not asserted.

The full app suite passes: 591 tests, one pre-existing intentional skip, no
failures. The two UI checks that look for `sync.status` in failed scenarios,
`testOfflineContentScenarioPreservesRecipes` and
`testAuthenticationExpiredScenario`, still pass.

Nothing automated covers the hidden title. The defect is paint outside the
strip's own bounds, beneath a system bar: a hosted strip measures the same
with or without it, and the project has no pixel comparison. The captures are
the evidence.

No capture of "Syncing recipes…" was staged. Demo launches have no sync
service, so `performSync` returns before `SyncStatus.begin()` and no existing
scenario reaches `.syncing`; none was added for a picture of removed UI.
