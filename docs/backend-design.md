# Ladle Backend — Design Guideline (v1)

Rough framework for the real backend that replaces `DemoImportService` and the
local-only account state. Written to be executed on a separate branch while UI
work continues on `main`. The iOS client's domain contract (`LadleCore`) is the
source of truth — the backend serializes to it, not the other way around.

## 1. Scope

**In scope (v1):**
- Import pipeline: social-video URL → fetched media/caption → transcript →
  structured recipe with per-field uncertainty → nutrition estimate.
- Auth: Sign in with Apple + anonymous guest identity, guest→account merge.
- Recipe storage + simple sync (client stays offline-first with SwiftData).
- Re-import from source, correction-notes re-parse, pasted-text fallback.

**Out of scope (v1):** social features, image generation, search service,
push-based sync, web app. Timers/notifications/HealthKit stay fully on-device.

## 2. Stack recommendation

| Layer | Choice | Why |
|---|---|---|
| API | **Python 3.12 + FastAPI** | The ingestion ecosystem (yt-dlp, faster-whisper) is Python-native; async fits the polling API; matches the digest project you already run |
| DB | **Postgres 16** | Relational core + `jsonb` for uncertainties; one DB for jobs and recipes |
| Queue/worker | **Redis + arq** (or Celery if preferred) | Import jobs are long-running (fetch + ASR + LLM); API must return immediately |
| Media fetch | **yt-dlp** | One tool covers YouTube/TikTok/Instagram; also yields caption/description metadata |
| ASR | **faster-whisper** (local, `small`/`medium`) with an API fallback | Cheap, private; recipe videos are short |
| Extraction LLM | **Claude `claude-opus-4-8`**, structured outputs via `client.messages.parse` | Schema-guaranteed JSON; adaptive thinking; see §7 |
| Object storage | S3-compatible (Cloudflare R2 / MinIO locally) | Thumbnails must be copied — CDN URLs from social platforms expire |
| Deploy | Single box/container to start (Fly.io / Railway / a VPS) | v1 traffic is one user; don't build for scale yet |

Everything runs as two processes: `api` (FastAPI) and `worker` (arq), sharing
Postgres + Redis. No microservices.

## 3. Architecture

```
iOS app ──HTTPS──► FastAPI (api)
                     │  POST /v1/imports          → insert job (status=parsing), enqueue
                     │  GET  /v1/imports/{id}     → job status (client polls w/ backoff)
                     │  GET  /v1/recipes …        → sync surface
                     │  POST /v1/auth/*           → Sign in with Apple / guest
                     ▼
                   Redis queue ──► worker (arq)
                                     1. resolve + fetch (yt-dlp)
                                     2. transcript (caption? else ASR)
                                     3. extract (Claude structured output)
                                     4. nutrition estimate
                                     5. dedupe check
                                     6. write recipe + job status
                   Postgres ◄──────┘        └──► R2/MinIO (thumbnail copy)
```

Client keeps its existing polling model (`ImportCoordinator` already polls the
demo service); no websockets needed for v1. APNs "import ready" push is a v2
nicety — the app already schedules a local notification on completion.

## 4. Data model (Postgres)

```
users            id, apple_sub (nullable, unique), created_at
devices          id, user_id, anon_device_id (for guest identity)
import_jobs      id (uuid, client-generated ok), user_id, source_url,
                 canonical_url, source (tiktok|instagram|youtube|manual),
                 status (parsing|ready|needs_review|failed),
                 failure_reason (parser_unavailable|private_or_deleted|
                                 unsupported_source|invalid_url|network_unavailable),
                 pasted_text, correction_notes,
                 recipe_id (nullable), created_at, updated_at
recipes          id, user_id, title, description, creator_name, source,
                 original_url, prep_minutes, cook_minutes, total_minutes,
                 servings, review_status (ready|needs_review),
                 nutrition jsonb, uncertainties jsonb,
                 image_key (object storage), deleted_at, created_at, updated_at
ingredients      id, recipe_id, order_index, quantity_text, unit, name,
                 uncertainty jsonb
steps            id, recipe_id, order_index, instruction,
                 ingredient_ids uuid[], uncertainty jsonb
```

Field names on the wire are the `LadleCore` names (`quantityText`,
`servingBasis`, `isEstimated`, `FieldUncertainty{field, reason, confidence}`,
…). Generate the OpenAPI schema from Pydantic models copied 1:1 from
`Packages/LadleCore/Sources/LadleCore/*.swift` and keep them in lockstep.

`canonical_url` = normalized URL (strip tracking params, resolve short links,
lowercase host). Unique index on `(user_id, canonical_url)` powers the
duplicate flow the client already has ("Already in your recipes" / "Import
another copy" — a second copy gets a `copy_of` suffix or a nulled canonical).

## 5. API contract

All under `/v1`, JSON, bearer token auth (guest or account).

```
POST /v1/auth/guest              → { token }            anonymous device identity
POST /v1/auth/apple              → { token, userID }    verify identityToken server-side
POST /v1/auth/merge              → guest recipes fold into the Apple account

POST /v1/imports                 { sourceURL | pastedText, correctionNotes? }
                                 → 202 { jobID, status: "parsing" }
GET  /v1/imports/{id}            → { status, failureReason?, recipe? }
POST /v1/imports/{id}/retry      { correctionNotes?, pastedText? }   (re-import / fix-up)

GET  /v1/recipes?updatedSince=   → delta sync (includes tombstones via deletedAt)
PUT  /v1/recipes/{id}            → client edit wins (last-write-wins on updatedAt)
DELETE /v1/recipes/{id}          → soft delete
```

Status values and failure reasons map 1:1 to `ImportStatus` /
`ImportFailure` in LadleCore (`parsing`, `ready`, `needsReview`, `failed` +
`parserUnavailable`, `privateOrDeleted`, `unsupportedSource`, `invalidURL`,
`networkUnavailable`). The client's state machine
(`StoredImportJob.transitioning(to:)`) doesn't change.

Guest limit: enforced client-side today; the server should also enforce it
(HTTP 402/409 with a typed error) so the limit survives reinstalls.

## 6. Import pipeline (worker)

Each stage writes progress to `import_jobs` so a crash resumes cleanly.

1. **Validate + canonicalize.** Unknown host → `failed(unsupportedSource)`;
   malformed → `failed(invalidURL)`. Resolve redirects/short links.
2. **Dedupe early.** Canonical URL already imported → return the duplicate
   outcome before spending money.
3. **Fetch (yt-dlp).** Pull metadata (title, uploader, description/caption,
   thumbnail) + audio track. Private/removed → `failed(privateOrDeleted)`;
   network/timeouts → `failed(networkUnavailable)` (retry ×2 with backoff
   first). Copy thumbnail to object storage.
4. **Transcript.** Prefer platform captions/description if they contain the
   recipe (many creators paste it — check before running ASR). Else
   faster-whisper on the audio. No usable audio/caption →
   `failed(parserUnavailable)`.
5. **Extract (Claude).** §7. Output includes per-field confidence.
6. **Nutrition estimate.** §8. Always `isEstimated: true`.
7. **Review gate.** Any field confidence < 0.7, or missing quantities on >30%
   of ingredients → `needsReview` with `uncertainties[]` populated
   (`FieldUncertainty(field: "ingredients[0].quantityText", reason, confidence)`
   — same shape the editor already renders). Else `ready`.
8. **Persist** recipe + flip job status atomically.

`correctionNotes` / `pastedText` (from `CorrectionNotesView`) get appended to
the extraction prompt on retry — pasted text skips stages 3–4 entirely, which
is also the reliable path when platforms block fetching (see §11).

## 7. LLM extraction

One call per import, structured outputs so the response is schema-valid by
construction (no JSON repair code):

```python
from anthropic import Anthropic

client = Anthropic()

resp = client.messages.parse(
    model="claude-opus-4-8",
    max_tokens=16000,
    output_config={"effort": "medium"},   # extraction is routine; bump if quality lags
    system=EXTRACTION_SYSTEM_PROMPT,      # frozen — enables prompt caching
    messages=[{"role": "user", "content": build_context(meta, transcript, notes)}],
    output_format=ExtractedRecipe,        # Pydantic model mirroring LadleCore.Recipe
)
recipe = resp.parsed_output
```

- `ExtractedRecipe` mirrors `Recipe`/`Ingredient`/`RecipeStep` plus a
  `confidence: float` and optional `uncertaintyReason: str` per field the
  client tracks uncertainty on. The prompt instructs: never invent
  quantities — emit low confidence with a reason instead ("The quantity was
  not spoken clearly" style, which the app already displays).
- **Prompt caching:** keep the system prompt byte-stable and put
  `cache_control: {"type": "ephemeral"}` on it; per-video content goes in the
  user turn.
- **Cost control:** cap transcript length (~15 min of speech), per-user daily
  import quota, and log `usage` per job into `import_jobs` for a cost column.
- **Refusals/errors:** treat API errors after SDK retries as
  `failed(parserUnavailable)` — same recoverable path the UI already handles.

## 8. Nutrition

v1: ask for the estimate in the same extraction call (per-serving calories,
protein, carbs, fat, satFat, fiber, sugar, sodium, `servingBasis`), always
flagged `isEstimated: true` — the UI already displays the "estimated"
disclaimers prominently, so LLM-grade accuracy is acceptable for v1.
v2: resolve ingredients against USDA FoodData Central and compute, keeping the
LLM only for quantity normalization.

## 9. Auth

- **Guest:** `POST /v1/auth/guest` with a client-generated UUID (stored in
  Keychain so it survives reinstall) → server mints a JWT bound to that device
  identity. This replaces nothing visible — `AccountSession` just gains a real
  token.
- **Sign in with Apple:** client sends the `identityToken`; server verifies
  the JWS against Apple's JWKS (`iss`, `aud` = bundle ID, `exp`), upserts the
  user on `apple_sub`, returns tokens. Access token short-lived (1h) +
  refresh token; both in Keychain.
- **Merge:** on first sign-in from a guest device, reassign the guest's
  recipes/jobs to the account — this is the "keep your 10 recipes" promise the
  welcome screen makes.

No passwords, no email flows in v1 — Apple only, which matches the current UI.

## 10. Sync

Keep the app offline-first; the server is durability + import brains, not the
live source of truth:

- Client pulls `GET /v1/recipes?updatedSince=` on foreground + after imports;
  applies upserts/tombstones into SwiftData.
- Client edits push `PUT` with `updatedAt`; conflict policy is last-write-wins
  (single-user data — real conflicts are rare; don't build CRDTs for v1).
- Existing Share-Extension queue keeps working: the main app drains the App
  Group queue by calling `POST /v1/imports`, replacing the demo path inside
  `ImportCoordinator`. **The `ImportService` protocol is the seam** — write a
  `RemoteImportService: ImportService` and the rest of the app doesn't change.

## 11. Reality check: fetching social video

TikTok/Instagram actively resist scraping, and doing it violates their ToS —
expect breakage and design for it rather than around it:

- YouTube is the reliable lane (captions API / yt-dlp works).
- Instagram/TikTok: try oEmbed + yt-dlp best-effort; when blocked, fail into
  `needsReview`/`failed(parserUnavailable)` and lean on the **paste-the-caption
  flow you already built** — that UX is the moat, keep it first-class.
- Never proxy fetches through user credentials; isolate the fetcher so a ban
  only degrades one source.

## 12. Local dev

Per the global Caddy convention (`41XY`, X = project index, Y = role; digest
holds X=9): allocate **X=1 → Ladle**, backend on **4111**.

- `Caddyfile`: `http://api.ladle.localhost { reverse_proxy 127.0.0.1:4111 }`
  then `caddy reload --config /opt/homebrew/etc/Caddyfile`.
- Run: `uvicorn app.main:app --port 4111` (pinned; never auto-pick) +
  `arq app.worker.WorkerSettings`; `docker compose` for Postgres/Redis/MinIO.
- iOS Debug builds point at `http://api.ladle.localhost` via an xcconfig
  value; simulator resolves `*.localhost` natively.

## 13. Phases

1. **Contract parity** — stand up API + Postgres + auth; port
   `DemoImportService`'s deterministic outcomes behind the real endpoints.
   Swap the app to `RemoteImportService`. Nothing user-visible changes; the
   client/server contract is proven.
2. **Real pipeline (YouTube only)** — yt-dlp + captions/whisper + Claude
   extraction + nutrition. Fixture recipes die here.
3. **Hard sources + hardening** — TikTok/Instagram best-effort, paste-flow
   polish, quotas, cost dashboards, APNs completion push.

Each phase is shippable; the app runs against phase 1 immediately.
