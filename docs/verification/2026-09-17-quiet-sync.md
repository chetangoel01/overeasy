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

## Affected components

- `Ladle/Library/LibraryView.swift` — `SyncStatusBanner` draws `.failed` only;
  its single-use `banner` helper folded into the body.
- `Ladle/Library/DiscoverView.swift` — `DiscoverRefreshBanner` draws `.failed`
  only; `DiscoverTopBar.systemImage` is no longer optional, because the
  spinner strip was the only caller without an icon.
- `Ladle/Library/WatchView.swift` — `discoverRefreshOverlay` draws `.failed`
  only.
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

The two UI checks that look for `sync.status` in failed scenarios,
`testOfflineContentScenarioPreservesRecipes` and
`testAuthenticationExpiredScenario`, still pass.

No capture of "Syncing recipes…" was staged. Demo launches have no sync
service, so `performSync` returns before `SyncStatus.begin()` and no existing
scenario reaches `.syncing`; none was added for a picture of removed UI.
