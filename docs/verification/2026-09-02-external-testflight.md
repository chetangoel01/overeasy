# Overeasy opens up: external TestFlight

Date: September 2, 2026
Status: **in progress. The code and content changes are here; the App Store
Connect steps and two registrar records are not done yet.**

Follows [Overeasy goes to TestFlight](2026-09-02-testflight-release.md), which
got build 1.0 (20260902.1) uploaded for internal testers. Internal testing asks
Apple for nothing. External testing asks for a review, a privacy policy at a
public URL, and a contact who answers — and it changes who holds the app.

## The API gate had to go

The shared Caddy gateway hid the whole API behind a header:

```
@authorized header X-Ladle-Tunnel-Key {$LADLE_TUNNEL_ACCESS_KEY}
```

The app sends that header on every request, reading it from `Info.plist`. That
worked while every build was installed over a cable, because the key reached
only devices we plugged in ourselves.

A public TestFlight link ends it. Anyone can install the app, read the key
straight out of the bundle, or watch it go past in a proxy — no jailbreak, no
cleverness. The key stops being a secret the moment the link is public.

So the matcher is removed and the API answers normally. What actually holds the
door is what always did: bearer tokens on every authenticated route, the guest
bootstrap for cooks who have not signed in, and the limits in
`ladle/api/rate_limits.py`. The header was obscurity layered on top, and
obscurity that everyone holds is worse than none, because it invites a trust it
cannot support.

Two details survive the change. The gateway still strips any incoming
`X-Ladle-Tunnel-Key` before proxying, because builds already in the world keep
sending it and it must never reach the application. And signed MinIO thumbnail
URLs under `/ladle-private/*` were never behind the header anyway — they
validate their own signatures.

`LADLE_TUNNEL_ACCESS_KEY` is now unreferenced by the route. It stays in the
gateway environment harmlessly; a later build can stop embedding it, and that
is the point at which it should be rotated and dropped for good.

## A privacy policy Apple can read

`docs/privacy-policy.md` was already thorough, and stays the single source.
`Tools/release/build_site.py` renders it, so the published page cannot drift
from the document the repository reviews. It also emits a support page and a
small index, in the app's own palette.

They publish with GitHub Pages from a `gh-pages` branch, live now at
**https://overeasy.chetangoel.me/privacy.html**, with support alongside it. GitHub Pages with a
custom domain was chosen over serving the page from the VPS for one reason: a
privacy policy must be reachable when the API is not. Putting it behind the
same gateway ties the document Apple reads to the uptime of the service it
describes.

The `CNAME` is written only when `build_site.py --cname` is passed, and it was
deliberately withheld until the DNS record existed. GitHub redirects the
`github.io` URL to the custom domain as soon as a CNAME appears, so publishing
one early would have replaced a working URL with a broken one. Links inside the
pages are relative for the same reason: they survive both `/recipe-app/` and a
domain root, so the flip needed no edit.

Two corrections went into the policy itself:

- **Health is write-only.** `HealthKitService` requests `read: []` — it can add
  the serving you export and cannot read anything back. The policy now says so,
  and adds the statement Apple looks for from a HealthKit app: the data is never
  used for advertising or marketing, never sold, never shared.
- **A contact exists.** The policy previously ended by admitting a public
  contact "must be added before App Store submission". It is now
  **hello@chetangoel.me**.

## Text for App Store Connect

**Beta App Description.** Overeasy turns a recipe video or a wall of pasted
text into a recipe you can cook from — ingredients, method, and timings, laid
out for a kitchen rather than a feed. Everything it makes is yours to edit, and
it syncs across your devices.

**What to Test.** Paste a recipe video link and watch the import. Check the
ingredients and the method against the source, and correct anything that came
out wrong — corrections are the point, not a failure. Try cooking from a recipe
with the step timers running. Tell us where the extraction lost something a
person would have kept.

**Review notes.** Sign-in is not required: the app opens straight into a guest
account with a working library, and Sign in with Apple is offered but optional.
Recipes are imported from public recipe-video links; any public cooking video
will do. Nutrition export to Apple Health is opt-in per serving and asks for
write permission only.

**Feedback email.** hello@chetangoel.me

**Sign-in required:** No.

## Still open

- Beta App Review wants a contact first name, last name, email, and **phone
  number**.
- Everything in App Store Connect: the external group, the build attached to
  it, Test Information filled from the text above, and the submission itself.
- The app record's **name**. Xcode reported the upload as "Ladle", which is the
  scheme name; if the record carries it too, that is what a tester sees in the
  TestFlight app. It should read Overeasy before any link goes out, and
  "Overeasy" may already be taken on the App Store, in which case the listing
  name needs a variant. Neither touches the bundle identifier.

Done since this document was started: the Caddy change deployed as `5024f1f`,
`overeasy` resolves to GitHub Pages, and `hello@chetangoel.me` forwards through
Porkbun's `fwd1`/`fwd2` mail servers.

## App Store screenshots

Six framed screenshots at **1320 x 2868**, built for the 6.9" slot, which App
Store Connect says covers "iPhone 6.5", 6.7" or 6.9" Displays" and is then
scaled for everything smaller: "we'll use these screenshots for all iOS display
sizes and localizations." One set is therefore the whole iPhone requirement,
and `TARGETED_DEVICE_FAMILY` of `1` means no iPad set is wanted at all. Only
the first three reach the install sheet, so the order is library, recipe,
timers.

`Tools/release/frame.swift` composes them: caption, accent rule, and the
capture inside a rounded device on a warm wash from the app's own palette.
Captures come from `xcrun simctl io ... screenshot` on the iPhone 17 Pro Max
(`FDD41CB2`), which renders 1320 x 2868 natively, so nothing is resampled to
fit. `Tools/release/flatten.swift` strips the alpha channel simctl always
writes; App Store Connect rejects a screenshot that carries one.

The device is dressed first: `simctl ui ... appearance light` and
`simctl status_bar ... override --time 9:41`, and the app is launched
`-ui-testing -onboarding-complete`.

### Two things the demo data had to stop doing

**It named real people.** `PreviewFixtures.swift` carried `@chebbo`,
`@iankyo`, `@iramsfoodstory`, `@sundaytable` and `JZ Eats` — real creators —
next to **real TikTok video IDs** pointing at their actual posts, in a public
repository. Putting those in store marketing claims an endorsement nobody
gave. They are now `@thecopperpan`, `@weeknightwok`, `@slowbutterbakes`,
`@themorningloaf` and `Sheet Pan Sunday`, with synthetic IDs. No test asserted
on any of them.

**It played other people's videos.** The Watch screen embeds the creator's
clip from the platform, which is the point of the screen and unusable in a
screenshot: a real ID shows a video we may not publish, and a synthetic one
shows the platform's "unavailable" page, which fills the frame with its own
recommendations — during this work that meant strangers' faces and a TikTok
logo. `InlineVideoPlayer` now recognises a `-ui-testing` build and loads the
recipe's own photograph dressed as a paused clip, through the same
`simulatedRequest` mechanism the YouTube host document already used. A recipe
from the demo Discover feed has a remote image rather than an asset, so it
falls back to the play chrome on a flat ground. Either way a demo build never
reaches a video platform, which also makes UI review independent of the
network and of whatever the platform served that day.

The share-sheet screenshot uses a mock recipe post served from a throwaway
local HTTP server, so no third-party page appears there either. It leaves one
blemish: the sheet names the source as `localhost`.

## Not tonight, on purpose

- **The ATS exception.** `NSAllowsLocalNetworking` and the `ladle.localhost`
  insecure-HTTP exception sit in the Release `Info.plist` because one plist
  serves both configurations. Beta App Review does not ask; App Store review
  will. The fix is a per-configuration `INFOPLIST_FILE`, and it wants a build,
  so it should ride along with the next one.
- **`NSHealthShareUsageDescription`** describes reading from Health, which the
  app never does. Harmless — it is a permission string for a permission never
  requested — but inaccurate, and worth deleting in the same build.
- **`health-records`** is enabled on the App ID in the developer portal though
  the entitlements file never asks for it. Portal cleanup, and it belongs to
  whoever holds the account.
- **App Attest** is the real replacement for the header gate:
  `LADLE_APP_ATTEST_ENABLED` is `NO` and the server does not enforce
  attestation. That is the work that would let the API tell a real Overeasy
  install from a script.

## Verification

`python3 Tools/release/build_site.py` renders all three pages; the policy came
through with its six sections, wrapped bullet items joined, bold runs
converted, and no markdown left unrendered. The result was opened in a browser
and reads correctly in dark mode.

The Caddy route deployed as `5024f1f` on September 2. `push.sh` ran
`caddy validate` — "Valid configuration" — before reloading, and the API and
worker reported healthy first.

Measured against the live host before and after, with no header sent:

| Request | Before | After |
| --- | --- | --- |
| `/health/ready` | 404 | 200 |
| `/v1/recipes/discover` | 404 | 401 |
| `/v1/auth/guest` (GET) | 404 | 405 |
| `/openapi.json` | 404 | 404 |

The 401 and the 405 are the point. Before, every path answered 404 whether it
existed or not, because the gateway refused to proxy at all — which is also
what made route probing so confusing earlier in this session. After, the API
answers for itself: 401 where authentication is required, 405 where the route
exists but the method is wrong, and 404 where nothing is. Authentication is
doing the work the header was pretending to do.

Sending a wrong `X-Ladle-Tunnel-Key` now behaves identically to sending none,
which is the proof the matcher is gone rather than merely loosened.
`/openapi.json` stays 404: the schema is not published in production.

Readiness reports every dependency healthy, `rateLimitRedis` among them — worth
naming, because the limiter fails open. If Redis goes away it logs "serving
request unlimited" and keeps serving. That is the right call for uptime and the
wrong assumption to make about a backstop, and it matters more now that the
limiter is the outermost thing standing.
