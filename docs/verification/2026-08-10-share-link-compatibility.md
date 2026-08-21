# Share-link compatibility

## Purpose and user-visible behavior

Sharing a recipe video to Overeasy now works when the source puts its URL in
the share item's attributed text instead of a URL or plain-text attachment.
The backend also accepts Instagram's `/share/reel/` URL shape and TikTok's
`/t/`, `vm.tiktok.com`, and `vt.tiktok.com` redirect forms, then stores the
same stable canonical source identity as their direct-link equivalents.

Malformed links, non-HTTP(S) links, and unsupported hosts remain rejected.

## Decisions and affected components

- `LadleShare/ShareURLExtractor.swift` checks each extension item's attributed
  text before its attachments. Existing URL and plain-text handling is
  unchanged.
- `Backend/ladle/imports/source_identity.py` normalizes Instagram's extra
  `/share` path component and sends current TikTok short links through the
  existing DNS-pinned redirect resolver.
- `Backend/ladle/infrastructure/dns.py` explicitly allows `vt.tiktok.com`
  while retaining per-hop DNS validation and IP pinning. No TikTok wildcard
  was added.
- No new dependency, URL abstraction, or client-side platform parser was
  added. The backend remains the source of truth for social URL identity.

## Verification

- The new Share Extension regression first failed with no extracted URL, then
  passed with the attributed-text fallback.
- The new Instagram and TikTok parser regressions first failed as invalid URL
  shapes, then passed after normalization and safe redirect routing.
- The `vt.tiktok.com` parser and pinned-resolver regressions first failed as
  unsupported, then passed after adding the exact short-link host.
- The reported `https://vt.tiktok.com/ZS4NEvuUH/` URL resolved live to TikTok
  video `7656390702540115203` and canonicalized successfully.
- Existing unsupported-scheme, missing-URL, direct URL, plain-text, social
  identity, and unsafe-host cases continue to pass.
- The complete Ladle test target passed on the iPhone 17 simulator. A Release
  simulator build passed and contains the embedded `LadleShare.appex`.
- The current backend suite passed: 510 passed and 5 skipped. Ruff formatting,
  Ruff lint, and strict mypy also passed.

## `vt.tiktok.com` device rollout

- The deployed VPS was still on preserved revision `99624ee`, so the hotfix
  release was built from that exact revision plus the current-share-link and
  `vt.tiktok.com` commits. All 780 tests passed with 5 skips before rollout.
- VPS revision `d560093` activated successfully after archive validation,
  migration, API, edge, worker, and Beat health gates. The previous revision
  remains available for rollback.
- The checked-in Release hostname, `api.ladle.app`, is parked behind
  `ns1.dan.com` and `ns2.dan.com` and fails TLS SNI. The Personal Team device
  build therefore uses the VPS's existing TLS hostname,
  `https://vps-8b0be574.vps.ovh.us`, plus its guarded tunnel key. The key was
  injected only at build time and matched without being printed.
- The replacement signed build installed and launched on the paired iPhone 17
  Pro. It refreshed the existing session, synced successfully, and submitted
  both reported `vt.tiktok.com` links with `202 Accepted`.
- `ZS4NEvuUH` canonicalized to TikTok video `7656390702540115203`, and
  `ZS4NEwJg6` canonicalized to video `7667383250049862925`. Both completed as
  `needsReview` with no failure reason, and both appear that way in the device
  Inbox.

## Empty-result correction

The two terminal jobs above were not valid successful imports. Both contained
an `Unknown Recipe` placeholder, an unknown ingredient, a fabricated missing-
method step, and no thumbnail. Worker logs exposed two related defects:

- yt-dlp failed on both current TikTok pages, but `FreeAcquirer` returned
  before attempting TikTok's independent public-page fallback;
- `PinnedHTTPClient` decoded TikTok's gzip response while streaming it and
  then rebuilt an HTTP response with the original `Content-Encoding` header,
  causing httpx to decode the same bytes again. This dropped both page evidence
  and oEmbed thumbnails.

The free TikTok rung now runs after a yt-dlp failure and reads the post caption,
creator, duration, thumbnail, English ASR, and sticker text from TikTok's page.
The pinned client retains its decoded byte limit while stripping stale encoding
and length headers from the buffered response. The orchestrator also rejects a
truly empty acquisition before model extraction, so an empty source becomes a
typed parser failure instead of a reviewable placeholder.

The live retry exposed one additional thumbnail handoff gap: cache-bypassing
re-imports downloaded the public thumbnail for extraction context but did not
persist it. A successful retry now stores that image and attaches it directly
to either the promoted current recipe or the needs-review candidate without
putting private correction text or the private extraction result into shared
cache.

Verification on 2026-08-21:

- both new regressions failed before production changes and passed afterward;
- the empty-acquisition integration regression failed as `completed` before
  the guard and now fails as `parserUnavailable` without calling extraction;
- retry-thumbnail regressions cover both an automatically promoted recipe and
  an isolated needs-review candidate;
- the exact two reported videos were probed live with the fixed acquisition
  path. Video `7656390702540115203` returned a 1,128-character caption, one ASR
  segment, creator metadata, and a thumbnail. Video `7667383250049862925`
  returned its caption, four ASR segments totaling 1,308 characters, creator
  metadata, and a thumbnail;
- the complete current backend suite passed with 513 tests and 5 live/chaos
  skips. Ruff format, Ruff lint, strict mypy, and `git diff --check` passed.

### Corrected live rollout

- The recovery and retry-thumbnail changes were transplanted onto the
  preserved VPS release line. Its complete backend suite passed with 783 tests
  and 5 expected skips; the focused thumbnail promotion/candidate tests, Ruff
  lint, strict mypy, and `git diff --check` also passed after the final change.
- VPS revision `1e5e16c` activated after archive, environment, Compose,
  migration, object-storage, API, edge, worker, Beat, and operations gates.
- Exactly one poisoned positive-cache entry was invalidated for each reported
  TikTok video. The two existing jobs were retried through the normal retry,
  quota, outbox, and worker services.
- Video `7656390702540115203` now saves as ready `Spicy Tofu & Chicken
  Noodles`, with 17 ingredients, 5 steps, and one private object-backed image.
- Video `7667383250049862925` now provides a needs-review `Fiber-Rich Cilantro
  Lime Rice` candidate, with 6 ingredients, 3 steps, and one private
  object-backed image. Both stored image objects passed an object-storage
  existence check.
- The signed app was terminated and relaunched on the paired physical iPhone
  17 Pro. Its synchronized library displays the corrected noodle recipe and
  thumbnail; the rice candidate remains isolated in Inbox until review is
  completed, preserving the app's safe re-import contract.

## Nutrition precision and adaptive layout correction

The corrected imports exposed a separate presentation and extraction-contract
bug on a real recipe with an 11-serving yield. The model returned per-serving
nutrition without a `servingBasis`, and the server substituted the recipe
yield. The app then divided already-per-serving values by 11 and rendered the
full repeating decimals. Those strings expanded grid rows, left large gaps
between cards, and crowded the recipe-detail metadata band.

The extraction prompt now states the nutrition basis contract explicitly:
per-serving values use a basis of one, whole-recipe totals name the number of
servings they represent, and nutrition is omitted rather than supported by
false precision. Calories are requested as whole numbers and gram values with
at most one decimal place. The structured-output schema repeats the basis rule,
and the server safely treats a missing basis as one. Prompt version
`recipe-2026-08-21-v9` keeps the changed wording and schema out of older cache
identities.

The iOS presentation also bounds every cook-facing nutrition value regardless
of the stored precision. Calories display as whole numbers and quantities use
at most one decimal place in the recipe archive, Watch, recipe detail,
nutrition, yield, and Health export confirmation. Archive metadata is capped at
two lines. At XXXL Dynamic Type the archive changes to one column and the
detail metadata band changes from three columns to stacked rows, before text
reaches accessibility sizes.

Verification on 2026-08-21:

- the Swift regression reproduced the reported values exactly as
  `4.999999… g P` and `56.818181… cal` before the fix, then passed with
  `5 g P` and `57 cal`;
- the backend regression first stored basis-less nutrition with a basis of 11,
  then passed with the promised per-serving basis of one;
- focused prompt tests pin the basis, non-null, and precision wording, plus the
  versioned prompt digest;
- all 515 backend tests passed with 5 expected skips; Ruff formatting, Ruff
  lint, and strict mypy passed;
- all Ladle app tests and all 43 LadleCore tests passed on the iOS 26.5
  verification simulator; the complete Release simulator build, including the
  Share Extension, also passed.
