# Text-Only Recipe Extraction

## Purpose

Recipe imports use written evidence only. Audio may be transcribed, but no
image, thumbnail, or video frame is sent to an extraction or observation
model. Sparse posts remain sparse until a trustworthy text source is found or
the import is explicitly refused.

## Allowed evidence

- platform title, caption, creator name, language, and source identity;
- TikTok sticker text and Instagram accessibility text published in the post
  page;
- native captions, platform speech-to-text, Whisper audio transcription, and
  transcript-provider output;
- written pages linked by the creator;
- independently fetched creator pages discovered by text-only web search; and
- user-pasted recipe text or correction notes.

The legacy `visual_observations` context field is retained for cache
compatibility, but acquisition filters it to the two platform-published text
provenances above. The extraction payload exposes those values as
`platformText` and discards provider-produced visual observations.

## Forbidden evidence

- sampled video frames or burned-in-text OCR;
- platform or provider visual-extraction endpoints;
- thumbnail or recipe-photo analysis;
- visual observations returned by a server-media fallback; and
- inferred quantities or actions based on what an image might show.

Thumbnail bytes may still be downloaded and stored for recipe-card display.
They are never passed to the extractor. The compatibility environment flags
`LADLE_FRAME_ANALYSIS_ENABLED` and `LADLE_THUMBNAIL_ANALYSIS_ENABLED` remain
parseable for older deployments, default to false, and have no runtime wiring.

## Runtime behavior

The provider chain tries free written context, audio transcription, and text
transcript providers. A server fallback may contribute transcript segments or
linked documents, never its visual observations. The prompt version changes
whenever this evidence contract changes so old cached extractions cannot be
served as though the new boundary produced them.

If those rungs still lack a quantified ingredient and a cooking action in a
transcript or linked page, the worker issues up to three exact searches based
on creator, dish title, canonical post URL, and platform post identity. The
OpenRouter client forces the beta `openrouter:web_search` server tool with the
Exa text engine. Search citations and snippets are discovery metadata only:
they never enter extraction evidence.

Every candidate page is fetched again through the DNS-pinned, redirect-checked
`SafeLinkFetcher`. A result is accepted only when its URL belongs to the
creator or resolves to the exact canonical post, its title/URL and fetched
body match the source dish, and the fetched body is substantial written text
containing both quantities and method. Generic same-dish pages, unrelated
recipes on the creator site, thin previews, unfetched snippets, and malformed
provider results are rejected. Only the first independently validated page is
attached, with provenance `creatorSearch`, to avoid mixing nearby recipes.

Successful, empty, and unavailable searches add `creatorSearchUsed`,
`creatorSearchNoMatch`, and `creatorSearchUnavailable` diagnostics
respectively. Search runs with no image or video understanding parameters.
`LADLE_CREATOR_SEARCH_MAXIMUM_QUERIES` and
`LADLE_CREATOR_SEARCH_MAXIMUM_RESULTS` bound latency and response size, not
price. Enabling this rung in a live worker requires an OpenRouter key.

After all text enrichment and user corrections, an evidence gate requires a
transcript or creator-linked page containing both a quantified ingredient and
a cooking action. Titles, promotional captions, and platform sticker/alt text
cannot satisfy this gate by themselves. A rejection happens before thumbnail
download and model extraction, persists no recipe, and completes the import as
`failed(insufficientTextEvidence)` with the same diagnostic code.

The iOS recovery surfaces this as missing written recipe detail and directs the
cook to paste the recipe or create it manually. This is distinct from an
unsupported host or a provider outage.

## Nutrition provenance

Prompt version `recipe-2026-08-24-v10` forbids the extraction model from
estimating nutrition, claiming that it ran USDA calculations, or inventing a
serving count to divide totals. Nutrition is returned only when the creator
states it in source text, with basis `creatorStated` and a short supporting
passage. Missing values stay absent for the deterministic nutrition stage.

The server accepts only `creatorStated` nutrition from model output and maps it
to `isEstimated=false`. Model output labeled `unknown` or `usdaCalculated` is
discarded; only the later deterministic USDA calculator may assign
`usdaCalculated`. The internal recipe template preserves this basis and its
evidence without changing the public iOS nutrition contract.

Each internal ingredient now retains its source metric amount/unit and a
normalized USDA search phrase derived from the ingredient name and preparation
state. These fields survive extraction review for deterministic matching but
are not exposed as creator claims in the public recipe DTO.

When creator-stated nutrition is absent, a live worker queries USDA FoodData
Central through its search and food-detail endpoints. It prefers Foundation,
SR Legacy, and FNDDS generic foods over branded results, then requires an
unambiguous ingredient-description match. The client accepts only the
documented kcal energy nutrients (preferring specific then general Atwater
energy) and gram-valued protein, carbohydrate, and fat nutrients. Complete
normalized query results are cached in-process.

The calculator converts source grams and standard mass units directly. Cups,
spoons, counts, and milliliters require a matching USDA portion with an
explicit gram weight; it never invents density or item size. Every material
ingredient must have a quantity, match one complete USDA record, and pass a
broad calorie-versus-macros consistency check. To-taste seasonings are omitted.
The whole-recipe totals are divided only by a creator-stated serving count,
then stored as `usdaCalculated` / `isEstimated=true` with the contributing FDC
IDs retained as internal evidence.

Any missing quantity, unsupported portion, ambiguous food match, incomplete
macro record, unknown serving count, or implausible nutrient record produces
no calculated nutrition. The recipe completes as `needsReview` with an
actionable nutrition uncertainty. USDA authentication, quota, transport, and
service failures follow the same non-terminal behavior; creator-stated
nutrition remains untouched and never calls USDA. Live workers require
`LADLE_USDA_API_KEY` when `LADLE_USDA_NUTRITION_ENABLED` is true.

## Affected components

- acquisition provider chain and Supadata client;
- creator-search client, safe linked-page fetcher, and worker configuration;
- worker and import-orchestrator construction;
- extraction prompt serialization;
- USDA FoodData Central client and deterministic nutrition calculator;
- VPS and local environment defaults;
- provider cost measurement; and
- thumbnail retry/reparse behavior.

## Verification

Verified on 2026-08-24:

- focused text-boundary tests: 104 passed, 4 integration cases deselected;
- retry/reparse PostgreSQL integration tests: 5 passed;
- complete unit and contract suite: 425 passed;
- Ruff: all affected application, script, unit, and retry/reparse files pass;
- strict mypy: 21 affected source files pass; and
- `git diff --check`: clean.

The evidence-gate slice additionally passed 12 focused unit tests, 21 combined
gate/coverage/contract tests, 6 PostgreSQL retry/reparse integration tests, the
complete 434-test backend unit/contract suite, all 44 LadleCore tests, and 161
Ladle iOS tests with one expected live-device test skipped.

The creator-search slice additionally passed the complete 452-test backend
unit/contract suite. Ruff passed all affected search, acquisition, runtime,
configuration, and test files; strict mypy passed all five affected source
files. Tests cover forced text-search payloads, citation parsing, SSRF-safe
refetching, ownership and dish matching, thin/non-recipe rejection, transcript
ordering, diagnostics, runtime construction, and the zero-visual boundary.

The nutrition-provenance slice additionally passed all 62 extraction tests and
the complete 458-test backend unit/contract suite. Ruff passed all affected
extraction, template, and test files; strict mypy passed all four affected
source files.

The deterministic USDA slice additionally passed 36 focused nutrition/review
tests, 172 nutrition/extraction/configuration/runtime/import regression tests,
all 8 PostgreSQL retry/reparse integration tests, the complete 491-test backend
unit/contract suite, and all 8 VPS deployment contract tests. Ruff passed the
full backend application and tests; strict mypy passed all 116 source files.
