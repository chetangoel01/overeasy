# The cooking session outlives its screen

Issue [#177](https://github.com/chetangoel01/overeasy/issues/177), from the phone
check for [#161](https://github.com/chetangoel01/overeasy/issues/161). Two faults
and the structural change both needed: timers died when the cook left the cooking
screen, and a timer notification's tap went nowhere.

## Purpose

A cook who steps out to the Watch tab, to another app, or out of the app entirely
keeps their timers. When one finishes, the alert leads back to the step that set
it, and while the app is in front it sounds through the Silent switch the way a
timer app does.

## Behaviour

**One session, owned by the app.** `CookingSessionStore`
(`Ladle/Cooking/CookingSessionStore.swift`) holds `active` — what is cooking —
and `presented` — what the full-screen cover is showing. The cover moved to the
app root (`Ladle/App/LadleApp.swift`), so a tap from any tab can raise it, and
dismissing it clears `presented` alone. The recipe page and Watch no longer own a
`CookingViewModel`; both read `isCooking(_:)` and show "Resume cooking" for the
recipe already going.

**Starting something else.** A session whose timers are still counting down asks
first: "End the timers for <title>?" with a destructive "End timers and start".
A session with nothing running is replaced silently. "Still running" is read from
the derived phase, so a timer whose deadline has already passed counts as
finished and never raises the dialog.

**Ending.** A session ends when the cook completes the recipe, when another
replaces it, or at sign-out. There is no "end cooking" control in the app and
this change did not invent one.

**Surviving a relaunch.** Every timer or step change writes a
`CookingSessionSnapshot` to `UserDefaults` under `cooking.active-session` —
recipe id, scaling, the whole `CookingSession`, and each timer's phase,
remaining-at-reference and reference date. `LadleRuntime` restores it at launch
by fetching the recipe from the repository; a missing recipe or an unreadable
snapshot drops it silently. Restoring does not present the cover. Timer requests
already live in the system's notification centre, so nothing is rescheduled.

**Alerts lead back to the step.** A timer notification is titled
"<label> is ready", says "<recipe title>, step <n>.", is Time Sensitive, plays
`TimerChime.wav`, and carries `recipeID`, `stepID` and `timerID`.
`NotificationDestination` is now a destination rather than a recipe id:
`.recipe` (import-ready, unchanged) or `.cookingStep`. Tapping a timer alert
moves the running session to that step and presents it, or starts a session
there — the replacement rule above still applies. The same destination is
reachable as `overeasy://cooking/<recipeID>/steps/<stepID>`, which is the
contract the Live Activity in #178 uses.

**The foreground alarm.** `TimerAlarm` (`Ladle/Cooking/TimerAlarm.swift`) sounds
the same chime through an `AVAudioSession` `.playback` category with
`.duckOthers`, plus a haptic, every 5 seconds, at most 6 times per timer.
Acknowledging is the finished timer card's existing Reset: the timer leaves
`.finished` and stops being rung for. In the background the notification is the
alarm and nothing extra happens.

## Decisions

- **Completing the recipe does not end a session with a timer still running.**
  A last step that says "rest for ten minutes" is ticked before its timer
  finishes; ending there would cancel the very alert this issue exists to keep.
  `isCompleted` is every step ticked *and* nothing counting down.
- **A timer that finished while the app was away does not ring on return.** Its
  notification was its alarm. `TimerAlarm.suppress(_:)` marks those timers as
  answered on a restore and on every background→foreground transition.
- **A foregrounded timer notification drops its sound.** `willPresent` returns
  `[.banner, .list]` when `userInfo` carries a `timerID`, because the alarm is
  already playing the same chime and the two together double the event.
- **The alarm borrows the audio category and gives it back.** Nothing else in
  the app sets one — Watch and the video sheet play through `WKWebView` — so a
  category left on `.playback` would have made every Watch video after the
  first chime sound through the Silent switch as well. The previous category
  and options are captured before the first chime of a run and restored once
  the sound finishes, whether or not `setActive(false)` succeeds.
- **Notification request identifiers are now derived from the timer id alone.**
  They used to carry a random suffix held only in memory, so a relaunched app
  could not cancel what a previous launch scheduled and a reset restored timer
  would still have alerted. Supersession is tracked by a separate token.
- **The store is threaded explicitly** through `RootView` → `LibraryView` →
  `WatchView`/`RecipeDetailView`, the way `syncStatus` and `libraryViewModel`
  already reach views, with no default value — a default-constructed store would
  be a session nothing presents.
- **The chime is synthesized, not sourced.** `Ladle/Resources/TimerChime.wav`:
  mono, 44.1 kHz, 16-bit, 1.20 s, 52,920 frames. Two bell-like tones — 880 Hz
  struck at 0 s and 1174.66 Hz at 0.42 s — each a fundamental plus second and
  third harmonics at 0.32 and 0.14 relative amplitude under an exponential decay
  (0.34 s and 0.40 s time constants), normalised to −3 dBFS with a 4 ms fade in
  and a 30 ms fade out so neither edge clicks. Generated by a throwaway Python
  script using only `wave`, `math` and `struct`; the parameters above are the
  script, and it is deliberately not carried in the repository.

## Affected files

- `Ladle/Cooking/CookingSessionStore.swift`, `Ladle/Cooking/TimerAlarm.swift`,
  `Ladle/Resources/TimerChime.wav` (new)
- `Ladle/Cooking/CookingViewModel.swift`, `Ladle/Cooking/RecipeTimer.swift`,
  `Ladle/Cooking/FullRecipeView.swift`
- `Ladle/App/AppBootstrap.swift`, `Ladle/App/LadleApp.swift`,
  `Ladle/App/RootView.swift`
- `Ladle/Notifications/UserNotificationService.swift`,
  `Ladle/Library/LibraryView.swift`, `Ladle/Library/WatchView.swift`,
  `Ladle/RecipeDetail/RecipeDetailView.swift`
- `Config/Ladle.entitlements` (`com.apple.developer.usernotifications.time-sensitive`),
  `Config/Ladle-Info.plist` (`overeasy` URL scheme, beside the Google one)

## Verification

Unit tests, on a simulator created for the run and deleted after it:

```
xcodebuild test -scheme LadleAllTests \
  -destination "id=<OE-177 iPhone 17 Pro, iOS 26.5>" \
  -only-testing:LadleTests
xcodebuild test -scheme LadleAllTests -destination "id=<same>" \
  -only-testing:LadleUITests/SmokeUITests/testPrimaryJourneyCapturesInboxDetailAndCooking
xcodebuild build -scheme LadleAllTests -destination "id=<same>"
```

`LadleTests/CookingSessionStoreTests.swift` covers start/resume, both
replacement paths, dismissal leaving the session running, ending, the snapshot
round trip (including a running timer's remaining time computed from its
reference date and an expired one restoring as finished), the dropped snapshot,
URL parsing, and both `.cookingStep` routes.
`LadleTests/TimerAlarmTests.swift` covers the cadence, the cap, acknowledgement
and suppression against a test clock and a fake player — no audio is touched.
`LadleTests/CookingViewModelTests.swift` now pins that leaving the screen keeps
pending alerts and only `endSession()` cancels them, and that a timer alert's
content carries its step.

## Not verified here

Audible delivery, the Time Sensitive interruption level against a real Focus,
and ducking behaviour are device matters; the simulator ignores provisioning, so
the entitlement may need enabling on the App ID before a device build signs.
The pending rows in `docs/verification/2026-09-17-timer-alerts.md` still stand.
