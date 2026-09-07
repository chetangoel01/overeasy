# Photo posts: caption-first import, and an honest hand-off when it comes up empty

Date: 2026-09-07 · Branch: `feat/photo-post-imports` · Issue: [#39](https://github.com/chetangoel01/recipe-app/issues/39)
Scope: backend only. The iOS failure copy is a follow-up.

## Why

TikTok serves recipe carousels at `/@user/photo/<id>` and the URL parser
rejected them outright, so a cook who shared one was told their link was
invalid. Instagram's `/p/` shape was already admitted, which was worse: an
image carousel walked the entire paid provider chain looking for audio that
does not exist and then failed anyway.

The probe that preceded this work — `docs/plans/2026-09-02-photo-carousels.md`
— measured 8 real TikTok recipe carousels and found the whole recipe in the
caption on 7 of them, extracted by the existing prompt with no change. The
decision recorded on issue #39 on 2026-09-07 is Route A: accept the URLs, read
the caption, and when the caption carries nothing, ask the cook. No OCR, no
vision over the slides.

## What changed

Three commits, one concern each.

### 1. Admission — `ladle/imports/source_identity.py`

`_TIKTOK_PATH` now matches `/@user/(video|photo)/<id>` and the canonical URL
keeps whichever kind it was given. Junk still fails: `/photo/abc`, `/photos/`,
a trailing path segment.

**Instagram needed no parser change.** `_INSTAGRAM_PATH` has always accepted
`/p/`, so image posts were already admitted; only the acquisition side needed
work.

**The kind is derived, not stored.** `media_kind_for_url` in
`acquisition/models.py` reads it off the canonical URL, and both
`SourceIdentity.media_kind` and `SourceVideoDescriptor.media_kind` are
properties over that one function. The canonical URL is already persisted, so a
carousel costs no column, no migration and no `expected_revision` bump — and
the fact cannot drift from the URL that states it.

Instagram is the exception the derivation names explicitly: `/p/` serves image
carousels, reel stacks and single videos from the same shape, so its kind
cannot be read from the path and is settled at fetch time instead.

### 2. Acquisition — how the caption is fetched

**TikTok.** The `/photo/` page carries no rehydration blob at all (probe §2.2).
The identical item — caption, author, stats, `imagePost` — is served at
`/@user/video/<id>`, so `TikTokPageClient` translates the URL before fetching
while the URL we store stays the one the cook shared. `imagePost.title` becomes
the title when there is no sticker to prefer, which on a carousel is almost
always: it is a real dish name where the caption's first line is a hook.

**yt-dlp is not run for a photo post at all.** This is the sharp edge the probe
found (§6): pointed at the `/video/` form of a carousel, yt-dlp returns one
audio-only stream — the licensed backing music. `_apply_ytdlp` would have set
`audio_url` to it, coverage on a hashtag caption is not sufficient, and Whisper
would have been billed to transcribe a Simple Minds record into evidence for a
recipe. Skipping it on the kind closes that before the call is made.

**Instagram.** `InstagramEmbedClient` reads `__typename` from the embed blob: a
`GraphImage`, or a `GraphSidecar` whose children are all images, is a photo
post. A stack holding even one video stays a video post and keeps its
transcript rungs — there is audio in there somewhere, and calling it a photo
post would silently give up on it.

**The paid chain stops.** `ProviderChain.acquire` returns after the free rung
for a photo post, with a `photoPostCaptionOnly` diagnostic. Whisper, Supadata,
SoScripted, the server fallback and the creator search are all hunting
narration; a carousel has none, so each is a call certain to fail. `check_public`
gets the same treatment, so a stale-source re-check cannot fall through to a
paid metadata call either.

`assess_coverage` and `has_recipe_evidence` were deliberately **not** touched.
Widening them is the line the whole provider ladder rests on, and returning
early makes it unnecessary.

**An unreadable page is an outage, not an empty carousel.** A page fetch that
failed and a carousel with no caption both arrive with an empty description.
Only the first is TikTok's problem, so `_photo_context` raises
`ProviderUnavailable` (→ `parserUnavailable`, retryable) rather than passing an
empty caption downstream. Telling a cook to type the recipe in because TikTok
was down would be a lie they cannot act on.

### 3. Hand-off — `photoPostNeedsManualEntry`

`PhotoPostNeedsManualEntry` subclasses `InsufficientTextEvidence`, so every
existing catch — the orchestrator's list, the retry rules — keeps working
unchanged. `_fail_terminal` checks it before its parent.

The failure is a distinct wire code because the two are different messages, not
different severities. "We couldn't read the recipe" reads as a verdict on the
cook's post; here the post is fine and the limitation is ours. The client should
say the recipe is in the pictures, that we could not read them, and offer
somewhere to type it.

## What the client must do

**`Packages/LadleCore/Sources/LadleCore/ImportJob.swift:3`** — add
`case photoPostNeedsManualEntry` to `ImportFailure`.

This is not optional and it is not "when convenient". `RemoteImportJobDTO`
(`RemoteContracts.swift:124`) declares `failureReason: ImportFailure?` with a
synthesized `Codable` and no unknown-case fallback, so an unrecognised string
throws a `DecodingError` on the **whole** poll response — not a missed switch
case, a broken import poll. The enum case, the `Contracts/Fixtures/import-failures.json`
entry and `RemoteContractTests.swift` must merge before this backend deploys.

Then the failure sheet maps the case to photo-specific copy — the recipe is in
the pictures, we could not read it, here is where to type it — reusing the
Paste recipe details / Create manually actions it already offers.
`Contracts/Fixtures/import-failures.json` is deliberately untouched here so
this PR does not red the Swift contract tests.

## Verification

Docker was up (`docker info`), so the integration suite ran for real.

```
uv run pytest                        955 passed, 10 warnings in 47.22s
uv run ruff format --check .         342 files already formatted
uv run ruff check .                  All checks passed!
uv run mypy --strict ladle           Success: no issues found in 127 source files
```

Tests added, in existing files:

| File | Covers |
|---|---|
| `tests/unit/imports/test_source_identity.py` | `/photo/` and `/video/` both admitted, canonical URL keeps the kind, malformed photo paths still rejected, short links resolve to a photo identity |
| `tests/unit/acquisition/test_free_tiktok.py` | struct read from the `/video/` form, `imagePost.title` as the title, a sticker still wins, a video post is never a photo post |
| `tests/unit/acquisition/test_free_instagram.py` | all-image sidecar and `GraphImage` are photo posts; a sidecar holding any video, and a reel, are not |
| `tests/unit/acquisition/test_free_acquirer.py` | yt-dlp is never invoked for a photo post (a runner that raises if called); the page is read even with subtitles disabled |
| `tests/unit/acquisition/test_free_chain.py` | no provider is touched for a photo post; Instagram recognised at fetch time; an unreadable page raises; a re-check pays nothing; **a video post still reaches the audio rung** |
| `tests/unit/extraction/test_evidence_gate.py` | recipe caption passes, hashtag caption and empty caption raise the subclass, a video post keeps the generic failure |
| `tests/integration/imports/test_retry_reparse.py` | a carousel with a recipe caption imports and extracts; one without fails `photoPostNeedsManualEntry` with nothing extracted and no recipe row |

No migration. No new dependency. No egress change. The extraction prompt is
unchanged: the caption already arrives as `metadata.description`, which
`SYSTEM_PROMPT` already describes as a caption, so the existing "use the
caption's spelling" guidance applies as written and `PROMPT_VERSION` did not
need a bump.

## Known limits

- A carousel whose recipe is burned into the slides — one of the eight in the
  probe — still cannot be imported. It now fails fast and free with the
  photo-specific code instead of slowly and expensively with the generic one.
  Vision over slides is deliberately out of scope; if the hand-off turns out to
  be the common case, that is a new issue with that evidence attached.
- `FreeAcquirer.counts` still routes TikTok through yt-dlp, so a count refresh
  on a carousel returns nothing. That is unchanged from TikTok video posts on
  server infrastructure, where TikTok rejects yt-dlp outright, and is not made
  worse here.
- The caption-sufficiency figure behind this route (7 of 8) is an upper bound:
  the probe's URLs were found by web search, which indexes posts by caption.
