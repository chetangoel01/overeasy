# App icon picker: one row, and a list for large text

Date: September 17, 2026
Issue: [#146](https://github.com/chetangoel01/overeasy/issues/146)
Branch: `codex/feedback-focus-and-icon-picker`
Status: **built, UI-tested through the real icon switch, and captured on a
simulator created for the task.**

## Purpose

The owner's feedback on the Profile picker: seven icons in a three-column
grid left Mushroom alone on a last row, and the selection's check badge hung
off the corner of its tile. The icons, their order and the switch itself are
unchanged; this is a layout pass. The earlier record of the picker is
[App icons, chosen in Profile](2026-09-08-plant-based-icon.md).

## What the cook sees

- The seven icons sit in **one row that scrolls sideways** inside the App icon
  section, so no icon is stranded on a row of its own. The visible row always
  ends on half a tile, which is what says it scrolls, and it settles on a
  tile's edge rather than part-way through one.
- **Selection is the accent ring, now around the artwork rather than over it,
  plus a small checkmark leading the caption, which turns semibold.** The
  corner badge is gone. Nothing draws outside its tile.
- At accessibility text sizes the row becomes a **standard list**: icon,
  name, and a trailing checkmark on the installed one.
- **Choosing an icon moves nothing.** The form keeps its scroll position and
  the row its offset, through the change and through the notice iOS puts up
  about it. That notice is the system's ([#147](https://github.com/chetangoel01/overeasy/issues/147));
  the picker adds no confirmation of its own.
- Every choice is still a named VoiceOver button whose value is "Selected" on
  the installed icon, with the same identifiers, at least 44 points each way.

## Decisions

The owner approved, on September 17: the single scrolling row with a peeking
tile, the ring plus caption check in place of the corner badge, the list at
accessibility sizes, and Profile holding its position through a change.

Engineering calls, each open to a veto:

1. **The tile width is computed so the row ends on half a tile at every phone
   width and text size**, never narrower than the 84 scaled points the longest
   caption needs. With a fixed width an iPhone 17 Pro showed most of a fourth
   tile, which read as clipped rather than as more to come. On that phone the
   row shows three and a half tiles; the mock drew four.
2. **The ring sits outside the artwork** on a 4-point gap, 2 points wide, as
   the mock draws it, instead of the 3-point stroke over the artwork's edge.
3. **Selection changes drawing, not structure.** The ring is always there and
   shown by opacity, the caption is one `Text` whose content changes, and the
   list's checkmark is hidden by opacity, so a selection cannot rebuild the
   row and lose its offset.
4. **The list's icon is 44 points** and its rows use the form's own button
   style, so they highlight like any other settings row.
5. **No new unit test.** `AppIconStoreTests` already covers selection, a
   refused switch and the no-op; this change is layout, which the UI test
   exercises through the real switch.

## Affected components

- `Ladle/Account/AccountSheet.swift`: `appIconSection` and its helpers.
- `LadleUITests/ProfileSheetUITests.swift`:
  `testTheLastIconInTheRowCanBeReachedAndChosen` replaces the seven-icon
  switching test, on the owner's instruction of September 17 to cut UI tests
  down to what a change actually risks. It drags the row until Mushroom, which
  starts off its end, is on screen, asserts the tile at least 44 points each
  way and inside the screen, chooses it through the real switch, and puts the
  egg back, which the diet tests' one-time offer depends on.
- `DESIGN.md` (Profile) and the [earlier picker record](2026-09-08-plant-based-icon.md).

## Verification

- The smoke test on iPhone 17 Pro, iOS 26.5: `Executed 1 test, with 0
  failures`, in 36 seconds against the 88 the seven-icon test took.
- Before it was cut down, the seven-icon test ran against the new row with
  the rest of its class: `Executed 9 tests, with 0 failures`. It took all
  seven icons through the real system switch, asserted each tile at least 44
  points each way and fully on screen before its tap, found each tile where
  it was once its selection landed, confirmed Mushroom after a relaunch, and
  put the original icon back.
- Position is no longer asserted; the captures below show it. The grid held
  its scroll position on this simulator too, so that assertion had been a
  guard rather than a fix seen going red.
- The diet test in the same class met the one-time avocado offer in that
  run, which needs the simulator back on the egg: the smoke test restores it.
- Full app suite: `Executed 591 tests, with 1 test skipped and 0 failures`,
  the skip being the live App Attest test. The primary-journey UI test
  (`StateScenarioUITests`) passes. Both ran on the final build of this branch,
  with the [Focus Mode amounts](2026-09-17-focus-step-amounts.md) in it.

## Captures

iPhone 17 Pro simulator, iOS 26.5, created for the task and deleted after it.
The owner's own phone capture of the grid in dark is the
[September 11 feedback screenshot](captures/2026-09-11-user-feedback/profile-icon-picker-layout.jpg).

| | Before | After |
| --- | --- | --- |
| Light | [grid, Mushroom alone, badge off the corner](captures/2026-09-17-app-icon-picker/before-light.png) | [one row, half a tile peeking](captures/2026-09-17-app-icon-picker/after-light-row.png) |
| Dark | [top of the grid](captures/2026-09-17-app-icon-picker/before-dark.png) | [row](captures/2026-09-17-app-icon-picker/after-dark-row.png) · [end of the row](captures/2026-09-17-app-icon-picker/after-dark-row-end.png) |
| Largest text | [light](captures/2026-09-17-app-icon-picker/before-light-ax5.png) · [dark](captures/2026-09-17-app-icon-picker/before-dark-ax5.png) | [list, light](captures/2026-09-17-app-icon-picker/after-light-ax5-list.png) · [list, dark](captures/2026-09-17-app-icon-picker/after-dark-ax5-list.png) · [its end](captures/2026-09-17-app-icon-picker/after-dark-ax5-list-end.png) |

Position through a change, with the form scrolled and the row at its far end:
[the system notice over an unmoved Profile](captures/2026-09-17-app-icon-picker/after-dark-system-notice.png),
then Mushroom chosen in [dark](captures/2026-09-17-app-icon-picker/after-dark-chosen-at-row-end.png)
and [light](captures/2026-09-17-app-icon-picker/after-light-chosen-at-row-end.png),
beside the same frame [before the tap](captures/2026-09-17-app-icon-picker/after-dark-row-end.png).

At the largest size "Strawberry" and "Mushroom" wrap onto a second line
beside the space kept for the checkmark. The space is kept on every row so a
selection cannot change a row's height.
