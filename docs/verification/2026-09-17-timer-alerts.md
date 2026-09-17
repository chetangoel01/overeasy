# Cooking timer completion alerts

Issue [#161](https://github.com/chetangoel01/overeasy/issues/161). The user asked
for confirmation that reaching zero produces a sound and an alert. Physical
sound delivery remains unverified; scheduling tests are not a listening test.

## Behavior and fix

The app requests alert/sound permission, schedules a one-shot notification with
the default sound, and presents foreground notifications as a banner, list
entry, and sound. A denied request leaves the in-app countdown usable. Pause,
reset, and ending cooking cancel pending requests. Navigation between steps
has no effect on an active timer's scheduled notification.

Review found two permission-delay defects: the scheduler started the full delay
after the permission prompt, and the cooking model canceled a completion if the
timer had naturally expired while permission was pending. The scheduler now
retains its original deadline. If permission arrives after it, delivery is
immediate. Natural completion no longer cancels that request; explicit pause
and reset still do. Request-generation checks continue to prevent stale work
from surviving cancellation or replacement.

Affected components: `Ladle/Cooking/RecipeTimer.swift` and
`Ladle/Cooking/CookingViewModel.swift`. The notification-center interface and
clock injection allow verification of actual notification content, deadline,
and permission races without relying on a system prompt in unit tests.

## Automated verification

Both regressions failed before the changes (three failed assertions). All 27
cooking/notification tests pass. They cover sound and alert authorization,
nonrepeating requests with a sound, timing before/after permission, immediate
late completion, denial, cancellation while authorizing, pause/reset/end,
and the foreground presentation options. The full app suite passes: 588 tests,
one pre-existing intentional skip, no failures. The test build compiles the
app and Share Extension.

## Physical verification still required

The reachable iPhone 17 Pro has Overeasy 1.0, build `20260910.2`. This is the
installed TestFlight baseline, without the permission-delay changes above.
iPhone Mirroring connected but navigation was unreliable, so no completed
cooking or audible-delivery test is claimed. The iPhone 14 Pro remained locked.

Record device/iOS/build, permission and sound settings, ringer volume, Silent
mode, Focus, and speaker/headphone routing alongside the results below.

| Scenario | Sound | Visible alert | In-app completion |
| --- | --- | --- | --- |
| Focus mode, foreground | Pending | Pending | Pending |
| Full Recipe, including a different step | Pending | Pending | Pending |
| App backgrounded, cooking session active | Pending | Pending | Pending |
| Phone locked | Pending | Pending | Pending |
| Pause/resume: only resumed deadline alerts | Pending | Pending | Pending |
| Reset/end: canceled deadline does not alert | Pending | Pending | Pending |
| Silent mode, Focus, sounds off, permission denied | Pending | Pending | Pending |

Do not close #161 until observed results are recorded or defects are linked.
