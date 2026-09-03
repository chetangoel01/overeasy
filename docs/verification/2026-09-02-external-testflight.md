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
**https://chetangoel01.github.io/recipe-app/privacy.html**. GitHub Pages with a
custom domain was chosen over serving the page from the VPS for one reason: a
privacy policy must be reachable when the API is not. Putting it behind the
same gateway ties the document Apple reads to the uptime of the service it
describes.

The `CNAME` for `overeasy.chetangoel.me` is written only when
`build_site.py --cname` is passed, and it is deliberately withheld until the
DNS record exists. GitHub redirects the `github.io` URL to the custom domain as
soon as a CNAME appears, so publishing one early would replace a working URL
with a broken one. Links inside the pages are relative for the same reason:
they have to survive both `/recipe-app/` and a domain root.

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

- DNS: `overeasy` CNAME to `chetangoel01.github.io`, at Porkbun. Then
  `build_site.py --cname`, republish `gh-pages`, and set the custom domain.
- Mail: `chetangoel.me` has no MX records at all, so `hello@` does not exist
  yet. Porkbun's own email forwarding is the shortest path.
- Beta App Review wants a contact first name, last name, email, and **phone
  number**.
- The Caddy change is committed but not deployed; it ships with
  `Backend/deploy/vps/push.sh`.

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

The Caddy route has **not** been validated on the VPS yet — `push.sh` runs
`caddy validate` before reloading, and that is the check that matters.
