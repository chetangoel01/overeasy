# Cooking timers on the Lock Screen and in the Dynamic Island

Issue [#178](https://github.com/chetangoel01/overeasy/issues/178). A cook with
the phone face-up on the counter should see a running timer's countdown and its
finish without unlocking anything, and see it with the ringer off — which is how
the phone check in [#161](https://github.com/chetangoel01/overeasy/issues/161)
found it. It sits on the app-owned cooking session from
[#177](https://github.com/chetangoel01/overeasy/issues/177), which is where the
session that outlives the screen, the relaunch snapshot and the tap destination
come from.

## Behaviour

Starting a cooking timer puts one Live Activity on the Lock Screen and in the
Dynamic Island, the way Clock does — one per running timer, not one per session.

- **Lock Screen and banner.** The timer's label, the recipe beneath it, the
  countdown right-aligned in monospaced digits, and a bar under both that fills
  as the timer runs down.
- **Dynamic Island.** Compact: a `timer` glyph leading, the countdown trailing.
  Minimal: the countdown alone. Expanded: the label leading, the countdown
  trailing, the recipe and the bar below.
- **Paused** freezes the digits at the remaining time, in the same `m:ss` the
  timer button shows, and freezes the bar where it stood.
- **Finished** replaces the countdown with "Done" and fills the bar. The label
  does not change: a cook reading "Loosen udon — Done" knows which pot.
- Acknowledging or resetting the timer takes the activity off at once; ending
  the cooking session takes all of them off, in the same method that cancels the
  pending notifications. A finish the app is in front for lingers five minutes
  rather than vanishing as the digits reach zero.
- **A relaunch takes its timers back.** `CookingSessionStore.restore()` adopts
  the activities the previous launch left — a timer the restored session still
  has counting down keeps the one already on the Lock Screen, moved to the
  deadline it came back with — and ends every other. A launch that restores no
  session ends them all, because nothing is left that could ever reach them.
- **Coming back to the foreground** takes a finished timer off the Lock Screen:
  it drew its own finish from the stale date while the cook was away, and the
  cook is holding the phone now.
- **A tap** opens the cooking screen at the timer's step, through the same
  `overeasy://` parsing and `CookingSessionStore.open(_:)` that a tapped timer
  alert uses.
- The timer notification still fires exactly as before. Nothing in the session
  waits on, or branches on, the activity: a phone that refuses Live Activities
  gets the timer, the alert and the screen it has always had.

The countdown and the bar are `Text(timerInterval:)` and
`ProgressView(timerInterval:)`, so the system advances them with the app
suspended. The app cannot run code when a backgrounded timer reaches zero, so
the activity's **stale date is the deadline**: the system marks it stale on
time, and the widget draws the finished appearance from that. A deadline already
behind us reads as finished too, which covers the moment between the two.

## Decisions

Owner decisions are recorded on #178 and were not re-opened. The calls made
while implementing it:

- **The bar fills; it does not drain.** A `countsDown: true` bar empties, which
  cannot then be "full at the finish". The running bar is
  `ProgressView(timerInterval: (deadline − duration)...deadline, countsDown:
  false)`, so it fills, is full at zero, and a resumed timer picks it up where
  the pause left it rather than restarting. The in-app ring still drains, because
  there the ring is the button's own glyph.
- **The activity is requested before the notification is scheduled**, not after.
  `startTimer` awaits notification permission, which can outlast a cook's
  patience; an activity requested after that await would show a timer the cook
  had already paused as still running. There is a test for the order.
- **The finish is observed on the screen's existing per-second refresh.** A
  timer's phase is derived from the clock rather than stored, so nothing in the
  view model mutates at zero. `RecipeTimerButton`'s `TimelineView` is the only
  place the app ever sees the transition — the same reason the finish haptic
  sits there — so an `onChange` beside the haptics reports it. A timer that
  finishes on a step the cook has left is not seen at all; the stale date draws
  that one, and phase 2's foreground pass clears it.
- **The countdown gets a column of its own**, `104pt` scaled with the text,
  rather than sharing the card's width with the title. Two findings from the
  captures, in order: with a plain `Spacer` between them the title and the
  spacer split what was left equally, so "15-Minute Garlic Butter Udon"
  truncated mid-word beside half a card of empty space; and `.fixedSize()` on
  the countdown — the obvious fix — stops the Lock Screen card drawing at all.
  `Text(timerInterval:)` asks for a very wide ideal, and a Lock Screen view
  that sizes itself to it is refused; only the Dynamic Island kept rendering,
  which is what made it look like a consent problem. A bounded width fixes
  both, and keeps the digits from shuffling the title sideways as they change.
- **`@preconcurrency import ActivityKit`.** `Activity` is not annotated
  `Sendable`, although `update` and `end` are meant to be called from anywhere.
  Without it every hand-off into the task performing the update is a strict
  concurrency error rather than the no-op it is.
- **Leftovers are adopted, not re-requested.** A relaunched app can still move
  and end the activities it left, so `restore()` adopts the ones whose timers
  are still running and lets the `start` that follows move them to their
  restored deadline. Requesting fresh ones instead would leave a stale twin on
  the Lock Screen beside each new one. Both calls are one line each in the
  store, into the presenter the session already holds; the store keeps its own
  presenter only for the launch that restores no session at all, where there is
  no view model to ask.
- **The `stepIndex` in the attributes is zero-based**, like
  `CookingViewModel.currentStepIndex`, and is derived from #177's
  `step(owning:)`, whose `number` is the one the cook reads. Anything shown
  adds one; there is one helper, not two.

## Target, plist and colour mechanics

- `LadleTimers` is a WidgetKit app extension declared in `project.yml` the way
  `LadleShare` is: bundle `com.ladle.ios.timers`, the app's iOS 26.0 deployment
  target, automatic signing, embedded by `Ladle`, and
  `NSExtensionPointIdentifier` `com.apple.widgetkit-extension` in
  `Config/LadleTimers-Info.plist`. No app group and no entitlement in v1.
  `Config/Ladle-Info.plist` gains `NSSupportsLiveActivities`.
- `Shared/CookingTimerActivity/` is compiled into both `Ladle` and
  `LadleTimers`. ActivityKit pairs an activity with its widget by the attributes
  type, so the two targets share the source. It names no `LadleCore` type, so
  the extension does not have to link the package; ActivityKit types stay out of
  `LadleCore` entirely. The `m:ss` format lives there too, because the Lock
  Screen shows a paused timer the same digits the app does.
- **Colours.** `LadleTheme` is app-only and xcodegen cannot hand a single
  `.colorset` to another target, so `LadleTimers/Assets.xcassets` holds a copy
  of `Plum.colorset` and nothing else. `LadleTimers/TimerActivityPalette.swift`
  restates the three roles the activity needs: `Surface.graphite` (the ground
  Focus Mode already cooks on) as `activityBackgroundTint`, the fixed
  `Label.onAccent` for content on it, and the fixed `Intent.focus` for the bar
  and the keyline tint. The last two are literals in `LadleTheme` as well, so
  only one colour is duplicated. The cook's chosen accent is app-only preference
  state and v1 shares no app group, so the activity wears the fixed Focus Mode
  signal rather than a stale accent. No gradients and no new colours.
- **Dynamic Type and VoiceOver.** Every text style is a system style, so the
  activity grows with the cook's text size. The countdown *is* the state —
  nothing purely visual carries it — and the bar is hidden from VoiceOver
  because the digits beside it already say the same thing in words. The header
  reads as "Loosen udon, step 1 of 15-Minute Garlic Butter Udon".
- The tap destination is `overeasy://cooking/<recipeID>/steps/<stepID>` with
  lowercase UUIDs. #177 registered the scheme and parses exactly that shape in
  `NotificationDestination(url:)`, so the app side needed nothing added: the
  URL travels through `LadleRuntime.handleOpenURL` into
  `CookingSessionStore.open(_:)`, the same path a tapped timer alert takes.

## Verification

Private simulator `OE-178` (iPhone 17 Pro, iOS 26.5), created for this run and
deleted after it.

```
xcodebuild test -scheme LadleAllTests -only-testing:LadleTests \
  -destination 'id=<OE-178>' -derivedDataPath /private/tmp/oe-178/dd -jobs 6
xcodebuild build -scheme Ladle \
  -destination 'id=<OE-178>' -derivedDataPath /private/tmp/oe-178/dd -jobs 6
```

- Unit suite: 556 tests, 1 pre-existing intentional skip, 0 failures. Eight are
  new: the presenter calls a session makes through start, pause, resume and
  reset; their order under a stalled permission prompt; ending the session; the
  attributes and tap URL built from a timer; the appearance a stale or elapsed
  deadline produces; a relaunch adopting a still-running timer's activity at its
  restored deadline; and the foreground pass. Two existing relaunch tests gained
  an assertion that a launch with nothing running ends what it inherited.
- `testTimerButtonFeedbackSitsInsideTheTimelineRefresh` still passes with the
  finish reporting added beside the haptics.
- The app builds with both extensions embedded:
  `Ladle.app/PlugIns/LadleTimers.appex` carries the widgetkit extension point,
  and the app's built `Info.plist` carries `NSSupportsLiveActivities`.
- No UI test was added. The captures below came from a scratch UI test driven
  once and deleted, as the testing rules require.

### Captures

`docs/verification/captures/2026-09-17-live-activity/`

| Capture | What it shows |
| --- | --- |
| `01-focus-mode-timer-running.jpg` | The timer started in Focus Mode, the session the activity mirrors |
| `02-dynamic-island-compact.jpg` | The app backgrounded: glyph and countdown in the compact island |
| `03-lock-screen-running.jpg` | The Lock Screen presentation, counting down |
| `04-lock-screen-finished.jpg` | The same timer past its deadline, drawn from the stale date with nothing of the app's running |

The expanded island is not scriptable — a long press is not something a UI test
can perform — so the compact state stands in for it, as #178 allows.

Two things in the Lock Screen captures are the simulator, not the app. iOS's
own first-run "Allow Live Activities from Overeasy?" consent is attached under
the card, because a scripted run meets it once per install and these were taken
before it was answered. The timer notification beneath is the alert that has
always fired, unchanged by this work.

### Not verified, and owed to a phone

The relaunch and foreground paths are proved by unit tests against the store's
own seams, not on a running app: `CookingSessionStore.restore()` is skipped for
the in-memory launch a UI test uses, so the scripted run cannot reach it. What
a device check should cover:

- **The launch reconcile against real ActivityKit.** `Activity.activities` is
  read from `LadleRuntime.init`, and if it comes back empty that early the
  adoption finds nothing, a fresh activity is requested, and the inherited one
  stays on the Lock Screen beside it. Kill the app with a timer running,
  relaunch, and look. If it happens, hop the reconcile a turn — it is
  fire-and-forget either way.
- **A tap on the activity** landing on the timer's step. The URL and its parser
  are unit-tested on both sides, but nothing has pressed the card.
- **Ending a lingering finished activity** — `end(.immediate)` after the
  five-minute `.after` — dismissing it at once. That path needs a cook to reset
  an acknowledged timer inside those five minutes.
- **The watch Smart Stack** the `.small` supplemental family is opted into.

Pause and Reset buttons on the activity are a separate follow-up, as #178 says.
