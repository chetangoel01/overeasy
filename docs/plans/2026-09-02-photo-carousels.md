# Photo carousels: probe result

**Issue:** [#39 — Decide whether TikTok photo carousels are importable](https://github.com/chetangoel01/recipe-app/issues/39)
**Status:** probe complete, **decision open**. This document measures; it does not choose.
**Date:** 2026-09-02

The issue asks three questions: are carousels worth supporting, caption-only or
vision, and does Instagram follow. This is the afternoon of measurement that was
the stated prerequisite. No product code was changed.

---

## 1. Method, and what it can and cannot tell you

Every page was fetched through the pipeline's own client — `SafeLinkFetcher` →
`PinnedHTTPClient` — from a residential IP on the developer Mac. Slides were
downloaded with `PinnedHTTPClient` directly. Instagram was driven through the
real `InstagramEmbedClient`; the "what happens today" trace ran the real
`SourceIdentityParser` and `FreeAcquirer`. Three captions went through the
production extraction prompt and client. Production was not touched.

**URLs were found by web search, and that biases the headline number.** Search
engines index TikTok posts by their caption text, so a carousel whose recipe is
in the caption is far more findable than one whose recipe is only in the
slides. Treat the caption-sufficiency rate below as an **upper bound**. The one
counterexample in the set — a seven-slide recipe card whose caption is five
hashtags — was reachable only because the hashtags included `#recipe`.

TikTok's own search, profile grids and Explore feed are all login-walled from a
server-side fetch and from an unauthenticated browser, and `yt-dlp`'s TikTok
user extractor returned only video items for the two creators sampled, so there
is no unbiased way to sample photo posts from this environment. That limitation is worth knowing before the number
is used to justify anything.

---

## 2. Four claims in the implementation brief that the code contradicts

These change the cost of both routes, so they come first.

1. **The egress allowlist is not in the way.** `ALLOWED_SOCIAL_HOSTS`
   (`infrastructure/dns.py:10`) is consulted only by `validate_public_target`,
   which only `PinnedRedirectResolver` (`dns.py:297`) calls — the short-link
   resolver. `PinnedHTTPClient.get` (`dns.py:198`), which `SafeLinkFetcher` and
   `MediaAudioSource` both use, calls `validate_external_target`: any public
   HTTPS host on port 443, with DNS re-resolution, private-range rejection and
   address pinning. **Slides were fetched from
   `p16/p19-common-sign.tiktokcdn-us.com` through that client with no code
   change**, 290–435 KB each, `content-type: image/jpeg`. Route B needs no
   allowlist edit and no new SSRF review; it needs a size cap and a slide cap.
   Instagram's slide `display_url`s sit on `scontent-*.cdninstagram.com`, which
   the same validator admits; those were read out of the embed blob but not
   downloaded.
2. **The `/photo/` page carries no item struct at all.** The brief expected the
   same struct with `imagePost.images[]` in place of a video. What is actually
   served at `/@user/photo/<id>` is a page whose rehydration blob has no
   `webapp.video-detail` scope — `_item_struct` returns `None` for all 13 URLs
   tried. The identical item **is** served at `/@user/video/<id>`, struct and
   all, `imagePost` included. The path is the switch, not the post.
3. **`yt-dlp --dump-json` does not list slide images.** yt-dlp 2026.08.19
   rejects a `/photo/` URL outright (`ERROR: Unsupported URL`). At the
   `/video/` form it returns the caption, two thumbnails, and **one audio-only
   m4a format — the licensed backing music**. See §6; this is the sharp edge in
   Route A.
4. **`CoverageReport.requires_review` is dead code.** Outside `coverage.py` it
   appears only in `tests/unit/acquisition/test_coverage.py:80`. Review status
   comes from `build_reviewed_template`'s `blocking` list
   (`extraction/review.py:120,130,257`). The only consumer of `assess_coverage`
   is `provider_chain.py` (lines 192, 216, 251, 262). So a coverage change in
   Route A moves **which paid providers run**, not what the cook sees labelled
   as needing review.

---

## 3. TikTok: 13 URLs, measured

`slides`, `imagePost`, caption and stickers are read from the struct at the
`/video/<id>` form. `qty`/`instr` are `coverage.py`'s `has_quantities` /
`has_instructions` over the caption alone. `gate` is
`require_recipe_evidence`, which is what decides whether an import survives to
extraction. The `/photo/` path yielded no struct on any of the 13; the `/video/`
path yielded a full struct on all 12 that were measurable.

| # | Post | Slides | Caption | qty | instr | qty mentions | Stickers | `imagePost.title` | gate | Recipe post? |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | [@reciperecipes/7659187617950420238](https://www.tiktok.com/@reciperecipes/photo/7659187617950420238) | — | — | — | — | — | — | — | — | **unmeasured** (stub struct, 3 attempts) |
| 2 | [@hollywoods_recipes/7659889402470026527](https://www.tiktok.com/@hollywoods_recipes/photo/7659889402470026527) | 1 | 2930 | yes | yes | 14 | 0 | "Hot Honey Garlic Chicken Tacos with Creamy Jalapeño Ranch" | pass | yes |
| 3 | [@therecipecollector/7664338461071035679](https://www.tiktok.com/@therecipecollector/photo/7664338461071035679) | 1 | 1987 | yes | yes | 10 | 0 | "Classic Creamy Raisin Rice Pudding Recipe (Na…" | pass | yes |
| 4 | [@umpachka23/7672357826672512269](https://www.tiktok.com/@umpachka23/photo/7672357826672512269) | 1 | 500 | yes | yes | 6 | 0 | — | pass | yes |
| 5 | [@jessielyncooks/7670607230961585439](https://www.tiktok.com/@jessielyncooks/photo/7670607230961585439) | **7** | 33 | no | no | 0 | 0 | — | **fail** | yes — **recipe is burned into the slides** |
| 6 | [@2days.delights/7592447747463073055](https://www.tiktok.com/@2days.delights/photo/7592447747463073055) | 1 | 699 | yes | yes | 6 | 0 | "Creamy Shrimp & Veggie Salad" | pass | yes |
| 7 | [@2days.delights/7619155597929237790](https://www.tiktok.com/@2days.delights/photo/7619155597929237790) | 1 | 2340 | yes | yes | 61 | 0 | "Popular American Condiments" | pass | yes |
| 8 | [@movieflavors/7580459860404227346](https://www.tiktok.com/@movieflavors/photo/7580459860404227346) | 5 | 1246 | yes | yes | 4 | 0 | "🍳🥔 Hobbit Second-Breakfast Skillet - Potatoes…" | pass | yes |
| 9 | [@godonlyknowsrecip/7610982510142442782](https://www.tiktok.com/@godonlyknowsrecip/photo/7610982510142442782) | 1 | 2065 | yes | yes | 17 | 0 | — | pass | yes |
| 10 | [@jazyri_q/7669539724960337173](https://www.tiktok.com/@jazyri_q/photo/7669539724960337173) | 1 | 26 | no | no | 0 | 0 | — | fail | **no** — a caption over a pot of pasta |
| 11 | [@laylanat_/7672331358965992725](https://www.tiktok.com/@laylanat_/photo/7672331358965992725) | 3 | 0 | no | no | 0 | 0 | — | fail | **no** — selfie carousel |
| 12 | [@attaaajaaa/7670685625367956757](https://www.tiktok.com/@attaaajaaa/photo/7670685625367956757) | 1 | 8 | no | no | 0 | 1 | — | fail | **no** — quote-over-photo |
| 13 | [@lucyredingvillarreal2/7671216204698127634](https://www.tiktok.com/@lucyredingvillarreal2/photo/7671216204698127634) | 1 | 0 | no | no | 0 | 1 | — | fail | **no** — screenshot |

Rows 10–13 were false positives of the search, kept here so the URL list is
complete. They also make a real point: `/photo/` is a general-purpose format,
and widening the parser admits a lot of non-recipe content that the pipeline
would then spend money on.

### What the struct exposes on a photo post

* `imagePost` — `{cover, images[], shareCover, title}`. Each `images[]` entry is
  `{imageURL: {urlList: [...]}, imageWidth, imageHeight}`.
* Slide URLs are **signed and expiring** (`x-expires`, `x-signature`). They must
  be fetched inside the same job; caching a URL is useless.
* A `video` key is still present, with `duration: 0` and `cover` pointing at the
  photomode JPEG. `subtitleInfos` is absent on every row, so `_english_track`
  correctly finds nothing and the TikTok ASR path is simply empty.
* `stickersOnItem` exists on photo posts (rows 12, 13) but was **empty on all
  eight recipe posts**. On-screen text on a recipe carousel is pixels, not
  stickers.
* `imagePost.title` is a genuine dish name on 5 of the 8 recipe posts, where
  `_sticker_title` returned nothing on all 8. That is a free title upgrade
  Route A should take.

### Slides: what is actually on them

Inspected by eye after downloading through `PinnedHTTPClient`.

* **#5, slide 2** — a full recipe card: dish name, "Servings: 24 pieces", four
  quantified ingredients, five numbered instructions. Caption is `#food #recipe
  #80s #retro #candy`. This single post is the entire argument for Route B.
* **#8, slide 2** — a styled food photograph with no text; the recipe is in the
  caption.
* **#11, #12, #13** — photo-with-text-overlay posts that are not recipes.

---

## 4. Caption sufficiency

Over the **8 measured TikTok recipe carousels**:

* `has_quantities` **and** `has_instructions` on the caption alone: **7 of 8
  (88%)**.
* Passes `require_recipe_evidence` on the caption alone: **7 of 8 (88%)** — the
  same seven posts.
* Caption + sticker text changes nothing: sticker text was empty on all eight.

**Read that as an upper bound, not an estimate.** See §1. A fair sample would
need TikTok search access this environment does not have.

Over the **6 measured Instagram carousels** (§5): **0 of 6**. Not one caption
carried a quantity.

---

## 5. Instagram: what happens today

`SourceIdentityParser` already accepts `/p/` (`source_identity.py:39`) and
canonicalises it to `https://www.instagram.com/p/<code>/`.
`InstagramEmbedClient` then requests **`/reel/<code>/embed/captioned/`**
regardless of kind (`free/instagram.py:53`) — and Instagram serves the post
there anyway. The accidental half-support is real: the caption comes back.

| Post | Creator | `__typename` | Slides | Children | Alt text | Caption | qty | instr | gate | `media_url` |
|---|---|---|---|---|---|---|---|---|---|---|
| [DVbn81xjyuP](https://www.instagram.com/p/DVbn81xjyuP/) | success.recipes | GraphSidecar | 12 | all images | 0 | 315 | no | no | **fail** | none |
| [DcL4pJhGjnA](https://www.instagram.com/p/DcL4pJhGjnA/) | soyasakthiprime | GraphSidecar | 5 | all images | 1 | 525 | no | yes | pass | none |
| [DaSvZ5MnJKf](https://www.instagram.com/p/DaSvZ5MnJKf/) | drericberg | GraphSidecar | 7 | all images | 0 | 565 | no | no | **fail** | none |
| [DZmEhxKjIYL](https://www.instagram.com/p/DZmEhxKjIYL/) | stylishachari | GraphSidecar | 12 | all video | 0 | 129 | no | no | **fail** | none |
| [DDlZmlAtvdX](https://www.instagram.com/p/DDlZmlAtvdX/) | erikatennille | GraphSidecar | 12 | all video | 0 | 240 | no | no | **fail** | none |
| [Da8GssEmFye](https://www.instagram.com/p/Da8GssEmFye/) | whylittletreats | GraphSidecar | 3 | all video | 0 | 597 | no | yes | pass | none |
| [DchoK5LDLar](https://www.instagram.com/p/DchoK5LDLar/) | — | — | — | — | — | — | — | — | — | embed served no `contextJSON` |

Three are image stacks and three are multi-reel carousels; the pipeline cannot
currently tell them apart, because `_media` reads only the top-level
`video_url`, which a sidecar does not have. So **`media_url` is `None` on every
one of them** — the Whisper path has nothing to download even for the video
carousels, whose per-child `video_url`s are sitting unread in the same blob.

Alt text (`accessibility_caption`, provenance `instagram:altText`) was present
on exactly one of six. It is not a usable slide-text source.

### The two terminal states

Executed: `SourceIdentityParser` → `FreeAcquirer` → `assess_coverage` →
`require_recipe_evidence`, all unchanged. `ProviderChain` itself was **not**
run — everything below about which paid rungs are attempted is read off the
code, not observed.

* **`DVbn81xjyuP`** — diagnostics `["instagramEmbedUsed",
  "freeCreatorPageUnavailable"]`; coverage `sufficient_for_extraction=false`,
  `has_recipe_evidence=false`; `require_recipe_evidence` raises. Terminal
  failure reason **`insufficientTextEvidence`**
  (`imports/orchestrator.py:543`). This is the issue's predicted "the import ran
  and produced nothing".
* **`Da8GssEmFye`** — same free rung, same coverage verdict, but the caption
  contains cooking verbs, so **the gate passes and extraction runs**. What comes
  back is in §7: a `needsReview` recipe with three ingredients, no quantities,
  and one step reading *"Swipe through the original carousel post slides…"*.

Both reach that state **after the whole paid chain has been offered the job**.
`assess_coverage(...).sufficient_without_transcription` is false, so
`provider_chain.py:193` does not short-circuit. Whisper is then reached with
`media_url=None`: `AudioTranscriptProvider.transcript` (`audio.py:529–558`)
gets `None` back from `MediaAudioSource.audio` and raises
`TranscriptUnavailable`, which `_audio_transcript` turns into the
`audioTranscriptionUnavailable` diagnostic. Nothing is downloaded and no ledger
row is written — `_record_provider` (`provider_chain.py:409`) writes to the
metrics registry only, and `TranscriptUnavailable` is not a
`ProviderUnavailable`, so it does not even reach that. **Supadata, SoScripted,
the server fallback and the OpenRouter creator search are then attempted in
turn** (`provider_chain.py:216–275`), and those are the calls that cost money.
What Supadata and SoScripted actually do with a `/p/` sidecar URL is
**unmeasured**; measuring it costs provider budget for no extra decision value.

TikTok, by contrast, is honest today: `/@user/photo/<id>` is rejected by
`_TIKTOK_PATH` with `InvalidSourceURL: invalid TikTok video path`, before any
network call.

---

## 6. The trap in Route A, measured

`FreeAcquirer.acquire` runs `_apply_ytdlp` **before** `_apply_tiktok_page` for
TikTok. Point yt-dlp at the `/video/` form of a photo post and it returns:

```
title:       '#food #recipe #80s #retro #candy '
duration:    60
formats:     [('audio', 'm4a', 'none')]
subtitles:   []   automatic_captions: []
track:       "Don't You (Forget About Me) - 12\" Version"   artists: ['Simple Minds']
```

`_apply_ytdlp` would set `context.audio_url` to that m4a. Coverage on a
hashtag caption is not sufficient, so `provider_chain.py:199` calls
`_audio_transcript` — and Whisper transcribes **a Simple Minds record**, billed,
and the lyrics become transcript evidence feeding the extractor. That is
strictly worse than today's rejection, and it is exactly what the issue warned
would happen if the regex were widened on its own. Any route that admits
`/photo/` must gate the audio path on the media kind in the same change.

---

## 7. Three caption-only extractions

Run through the production `SYSTEM_PROMPT` + `build_user_prompt` +
`OpenRouterStructuredClient` on `google/gemini-3.7-flash`, then
`build_reviewed_template`. Nutrition and verification were not run.

| Case | Gate | Ingredients (no qty) | Steps | `method_provenance` | `review_status` | Judgement |
|---|---|---|---|---|---|---|
| TikTok #2, 2930-char caption | pass | 28 (1) | 10 | explicit | **ready** | Correct and complete. Title, 6 servings "stated", the full method. Cookable. |
| TikTok #4, 500-char caption | pass | 8 (2) | 4 | explicit | **ready** | Correct. Servings estimated from yield, flagged as an uncertainty. Cookable. |
| Instagram `Da8GssEmFye`, 597-char caption | pass | 3 (3) | 1 | **inferred** | **needsReview** | Junk. Title "Three Recipes: Pav Bhaji, Chole Bhature & Mushroom Pepper Fry"; ingredients "mushrooms, pepper, butter"; the single step is *"Swipe through the original carousel post slides to view the detailed preparation…"*. |

The existing extractor handles a recipe-bearing caption without any change. It
also fails safely on a promo caption — `blocking` catches both the missing
quantities and the inferred method, so the cook sees `needsReview` rather than a
confident fabrication. The failure mode is wasted money and a wasted wait, not a
wrong recipe.

One caveat on the two TikTok cases: the harness passed `imagePost.title` as the
context title. Today's pipeline never reads that field, so it would start from
the caption's first line instead. Route A should adopt `imagePost.title` (§3).

---

## 8. The routes, costed

### Route 0 — reject `/photo/` with a clear message

The issue's first question deserves a line, because it is nearly free.

* **Files:** `imports/source_identity.py` (one distinct message for a
  `/photo/` path), one unit test, and whatever the iOS import error surface maps
  it to.
* **Dependencies / egress / provider cost:** none.
* **Risk:** none. The cook is told the app does not do carousels yet, instead of
  being told their URL is invalid.
* **What it costs the product:** by the measured set, 8 of 13 photo URLs were
  real recipes and 7 of those 8 carried a full recipe in text the pipeline could
  already read. That is the opportunity being declined.

### Route A — caption-first

Parser accepts `/photo/`; a media kind rides along; the free acquirer skips
audio for it; coverage counts the caption as recipe evidence for photo posts
only when it has quantities **and** instructions.

* **Files touched**
  * `imports/source_identity.py` — accept `/photo/<id>`, carry a kind.
  * `acquisition/free/acquirer.py` — skip `_apply_ytdlp` (or its audio fields)
    for the kind; `_apply_tiktok_page` must request the `/video/` form since
    that is where the struct lives; `counts()` needs the same treatment.
  * `acquisition/free/tiktok.py` — read `imagePost` for slide count and
    `imagePost.title`; keep `_english_track` returning `None` (it already does).
  * `acquisition/coverage.py` — `has_recipe_evidence` is computed from
    `recipe_text` = transcript + linked documents only (`coverage.py:61–78`).
    Making a photo caption count means passing the kind in and widening that one
    expression. This is the load-bearing line for both routes.
  * `acquisition/free/instagram.py` — read `__typename` and
    `edge_sidecar_to_children` to set the same kind for a `GraphSidecar`.
    Without this, Route A is TikTok-only and §5 is unchanged: nothing in the
    Instagram client can tell a carousel from a reel today.
  * `acquisition/provider_chain.py` — the kind must reach `assess_coverage`, and
    the **whole transcript rung set** must be skipped for it, not just Whisper:
    `_audio_transcript`, Supadata, SoScripted and the server fallback
    (`provider_chain.py:199–260`) are all searching for audio that a photo post
    does not have. The brief said "short-circuit both"; the specific rungs are
    these four.
  * Tests: `tests/unit/imports/test_source_identity.py`,
    `tests/unit/acquisition/test_coverage.py`, free-acquirer tests, Instagram
    embed tests for the sidecar shape, and a new test that a photo post reaches
    none of the four transcript rungs.
* **Canonical-URL fork — pick one, the costs differ**
  * **(a) canonicalise to `/video/<id>`** — `TikTokPageClient` and yt-dlp both
    work unchanged, and no fetch logic moves. But `original_url` on the saved
    recipe then points at a `/video/` URL for a photo post, and yt-dlp still
    hands back the music track, so the audio gate becomes mandatory rather than
    merely prudent.
  * **(b) canonicalise to `/photo/<id>`** — honest `original_url`, and yt-dlp
    refuses the URL outright so the audio trap closes by itself. Costs a
    translation inside `TikTokPageClient` (fetch the `/video/` form for the same
    id). It also makes `FreeAcquirer.counts` **silently return empty
    `SourceCounts()`** for the kind — it calls
    `self._ytdlp.metadata(source.canonical_url)` and swallows
    `ProviderUnavailable` — so likes and views would quietly stop refreshing
    unless counts are routed through the page client too.
* **Media kind — persisted or derived**
  * **Derived** (from the URL path, or from `imagePost` being present in the
    struct): no migration, no `expected_revision` bump, no fixtures. `SourceVideo`
    has no kind column today (`db/models.py:265–305`), and nothing else wants
    one yet.
  * **Persisted** on `SourceVideo` / `SourceVideoDescriptor`: a migration, an
    `expected_revision` bump in `api/routes/health.py`, plus
    `Contracts/Fixtures/*.json`, `Backend/tests/contracts/` and
    `RemoteContractTests.swift` per the working agreement. Roughly doubles the
    change.
* **New dependencies:** none. **Egress changes:** none. **Provider cost:**
  **negative, but only if the transcript rung gate above is part of the change.**
  A covered caption stops the chain at `sufficient_without_transcription`; an
  uncovered one (the jessielyncooks shape) would otherwise still walk Supadata,
  SoScripted, the server fallback and the creator search before the gate kills
  it — paying transcript providers to look for audio that cannot exist. With the
  gate, a carousel import costs one extraction call or nothing at all.
* **Risk:** moderate, and concentrated in two places. Widening
  `has_recipe_evidence` is the rule the whole ladder rests on, and getting the
  kind gating wrong lets a caption stand in for narration on ordinary videos.
  The audio trap in §6 is the other; it is a test, not a mystery.
* **What it does not fix:** the jessielyncooks case, and any carousel whose
  recipe is only in the slides. For those, Route A's honest outcome is a fast,
  cheap `insufficientTextEvidence` instead of today's slow, paid one — better,
  but still not an import. Instagram improves only if the
  `free/instagram.py` bullet is included; without it, §5 is unchanged.

### Route B — vision over the slides

Slides fetched, passed to the model as images, emitted as `VisualEvidence` with
a `slideText` provenance, metered like every paid call.

* **Files touched — everything in Route A, plus**
  * A slide fetcher: `PinnedHTTPClient` directly (not `SafeLinkFetcher`, whose
    `Accept` header is text-only and whose `fetch_text` drops non-HTML). Needs a
    slide cap (TikTok allows up to 35) and a per-image `max_bytes`; measured
    slides were 290–435 KB.
  * `extraction/openrouter.py` — `parse_recipe` sends
    `{"role": "user", "content": user_prompt}` as a **plain string**
    (`openrouter.py:125`). Images need the array content shape, which means a new
    method or a second client; the same for `extraction/claude.py` if the
    Anthropic provider is to keep parity.
  * **`acquisition/provider_chain.py:33`** — `_PLATFORM_TEXT_PROVENANCES =
    {"instagram:altText", "tiktok:sticker"}` filters `visual_observations`
    before they reach the context. `slideText` must be added or the evidence is
    dropped on the floor.
  * **`extraction/prompt.py:236`** — the same allowlist is **hardcoded a second
    time** in `build_user_prompt`'s `platformText` block. Both must learn the new
    provenance.
  * **`extraction/evidence_gate.py`** — `require_recipe_evidence` joins
    description + transcript + linked documents and **not**
    `visual_observations`. Without a change here, a post whose recipe is only in
    the slides still dies at the gate *after* the vision call has been paid for.
  * **`extraction/verification.py:90–115`** — `verification_evidence` likewise
    excludes visual observations, so the verifier would treat slide-derived
    ingredients as unsupported.
  * `acquisition/coverage.py` — same widening as Route A, extended so slide text
    counts as recipe evidence.
  * Metering: copy `RecipeExtractor.extract`'s shape
    (`extraction/claude.py:113–172`) — `usage.started` / `completed` with one
    billed unit per provider call and `cost_usd` from the response. A new
    `operation` name alongside `recipeExtraction`.
  * Tests, including an SSRF test for the slide fetcher in the shape of
    `tests/unit/acquisition/test_media_ssrf.py`.
* **New dependencies:** none required. No OCR library is needed if the vision
  model reads the slides; a local OCR pass would be a different (cheaper,
  weaker) variant worth its own comparison.
* **Egress changes:** **none** — see §2.1. Slides were fetched through the
  existing pinned client during this probe.
* **Provider cost:** one image-bearing call per import, with up to 35 images.
  Unmeasured — see §10.
* **Risk:** higher. It is the first place in the pipeline where pixels become
  recipe evidence, and `VisualEvidence` currently means "the platform told us
  this text exists" rather than "a model read it off an image". The four
  provenance/gate sites above are each a silent-drop bug if missed. It also
  raises a product question: a slide that says "1½ cups salted peanuts" is the
  creator's own writing, but a model's reading of it is not, and the
  `has_recipe_evidence` doctrine in `coverage.py:36–44` is built on that
  distinction.

### Prerequisite ordering

Route A's parser and coverage work is a prerequisite for Route B, as the brief
states, and the probe confirms why concretely: without the kind, the parser
rejects the URL; without the coverage change, slide text does not count as
recipe evidence no matter how good the vision call was. **B is A plus roughly
its own size again.** Route 0 is independent of both and could ship this week.

---

## 9. Recommendation

**My recommendation is Route A now, with Route B held open and unbuilt.** The
decision is yours.

Seven of the eight measured recipe carousels carry the whole recipe in text the
pipeline can already read for free, and when that text is handed to the existing
extractor it produces a `ready`, cookable recipe with no prompt or contract
change (§7). That is a real feature for a change whose sharp edges are two
known, testable gates — the audio trap in §6 and the coverage line in §8 — and
whose provider cost comes out negative, provided the transcript-rung gate is
part of the same change: a covered caption stops the paid chain that a carousel
import burns today, and an uncovered one fails before reaching it. Taken with
its `free/instagram.py` bullet, Route A also converts the Instagram behaviour in
§5 from an accident into a decision: a sidecar is recognised as a carousel, the
transcript rungs stop being asked for audio that does not exist, and a promo
caption fails fast instead of after the bill.

The reason I would not start Route B is that this probe cannot tell you how
often it is needed. The one post that requires it (§3, #5) is genuinely
un-importable without vision, and its recipe card is beautifully legible — but
the sample that produced it is biased against exactly that kind of post, so 1
in 8 is a floor, not a rate. Ship A, add a diagnostic that counts photo imports
which reach `insufficientTextEvidence` with slides present, and let a month of
real cooks' shares answer the question this afternoon could not.

If instead the answer is that carousels are not worth it yet, **Route 0 is the
honest version of today's behaviour** and should be taken rather than leaving
the Instagram half-support as it is — that path currently spends the full paid
chain to produce a failure or a junk `needsReview`, which is the worst of the
three.

---

## 10. Follow-up questions for whoever picks this up

1. **Does `google/gemini-3.7-flash` on OpenRouter accept images, and what does a
   slide cost?** Not measured — it needs a real multimodal call, which is a
   build step, not a probe step. Route B's per-import cost is unknown until it
   is answered.
2. **Persisted media kind or derived?** §8 costs both. Derived is much smaller;
   persisted is the right answer if anything else will ever want to know.
3. **Canonical URL: `/photo/` or `/video/`?** §8. It is a product question about
   what `original_url` should say as much as an engineering one.
4. **Should a model's reading of a slide count as `has_recipe_evidence`?** The
   doctrine in `coverage.py:36–44` says a caption is not evidence because it is
   not the creator reporting the dish. A recipe card the creator designed is
   arguably stronger evidence than narration. Route B needs that settled.
5. **Instagram sidecar children carry per-child `video_url`s that `_media` never
   reads.** Worth a separate issue regardless of this decision: three of the six
   carousels here are multi-reel posts with downloadable audio sitting unread.

---

## 11. What could not be measured, and why

* **An unbiased sufficiency rate.** §1. Search-derived URLs over-represent
  caption-bearing posts.
* **`@reciperecipes/7659187617950420238`** returned a stripped item struct on
  three attempts (no `desc`, no `author`) while every other URL succeeded.
  TikTok's anti-automation response, most likely. Left as unmeasured rather than
  guessed.
* **Reachability from the VPS.** Everything here ran from a residential IP.
  `tiktok.py`'s own docstring notes TikTok rejects yt-dlp from datacenter
  addresses, and `_counts`' comment says the page fetch is the only count source
  that works on server infrastructure. Whether `/@user/video/<photo_id>` returns
  a struct from the VPS is **untested** and should be the first thing checked if
  Route A is picked.
* **Supadata and SoScripted on a `/p/` sidecar.** They are attempted today; what
  they return was not measured, because it costs provider budget and changes no
  decision here.
* **Vision cost per slide.** §10.1.
* **Provider spend during this probe:** six OpenRouter extraction calls, three
  of which were lost to a serialization bug in the scratch driver before the
  three reported in §7. No other paid provider was called. No secrets were
  printed or copied.

---

## Appendix — every URL, and how it was found

Search was DuckDuckGo, driven in a browser (TikTok `/photo/` URLs are not
returned by the search tooling's default index, and TikTok's own search,
profile grids and Explore feed are login-walled).

Queries used:

* `site:tiktok.com inurl:photo recipe` → rows 1–5, 10–13
* `site:tiktok.com inurl:photo ingredients tbsp` → rows 6–9
* `site:instagram.com inurl:/p/ recipe ingredients carousel swipe` → all
  Instagram URLs
* `site:tiktok.com inurl:photo jessielyncooks OR "recipe card" ingredients`,
  `site:tiktok.com inurl:photo "1 cup" OR "servings" recipe instructions`,
  `site:tiktok.com inurl:photo easy dinner recipe` → **no results**

TikTok (all fetched at both the `/photo/` and `/video/` forms):

```
https://www.tiktok.com/@reciperecipes/photo/7659187617950420238
https://www.tiktok.com/@hollywoods_recipes/photo/7659889402470026527
https://www.tiktok.com/@therecipecollector/photo/7664338461071035679
https://www.tiktok.com/@umpachka23/photo/7672357826672512269
https://www.tiktok.com/@jessielyncooks/photo/7670607230961585439
https://www.tiktok.com/@2days.delights/photo/7592447747463073055
https://www.tiktok.com/@2days.delights/photo/7619155597929237790
https://www.tiktok.com/@movieflavors/photo/7580459860404227346
https://www.tiktok.com/@godonlyknowsrecip/photo/7610982510142442782
https://www.tiktok.com/@jazyri_q/photo/7669539724960337173
https://www.tiktok.com/@laylanat_/photo/7672331358965992725
https://www.tiktok.com/@attaaajaaa/photo/7670685625367956757
https://www.tiktok.com/@lucyredingvillarreal2/photo/7671216204698127634
```

Instagram:

```
https://www.instagram.com/p/DVbn81xjyuP/
https://www.instagram.com/p/DcL4pJhGjnA/
https://www.instagram.com/p/DaSvZ5MnJKf/
https://www.instagram.com/p/DZmEhxKjIYL/
https://www.instagram.com/p/DDlZmlAtvdX/
https://www.instagram.com/p/Da8GssEmFye/
https://www.instagram.com/p/DchoK5LDLar/
```

Pages that were fetched and yielded nothing, recorded so nobody repeats them:
`tiktok.com/discover/photo-carousel-tiktok-recipe`,
`tiktok.com/discover/recipe-carousel`, `tiktok.com/discover/recipes-carousel-post`,
`tiktok.com/tag/recipe`, `tiktok.com/@justine_snacks`, `tiktok.com/@thekoreanvegan`,
`tiktok.com/@emilymariko` — none carries a `/photo/` link or an `imagePost` item in
its server-rendered blob.

The probe drivers were scratch scripts and are not committed; everything they
produced is recorded above.
