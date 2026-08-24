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
- written pages linked by the creator; and
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

After all text enrichment and user corrections, an evidence gate requires a
transcript or creator-linked page containing both a quantified ingredient and
a cooking action. Titles, promotional captions, and platform sticker/alt text
cannot satisfy this gate by themselves. A rejection happens before thumbnail
download and model extraction, persists no recipe, and completes the import as
`failed(insufficientTextEvidence)` with the same diagnostic code.

The iOS recovery surfaces this as missing written recipe detail and directs the
cook to paste the recipe or create it manually. This is distinct from an
unsupported host or a provider outage.

## Affected components

- acquisition provider chain and Supadata client;
- worker and import-orchestrator construction;
- extraction prompt serialization;
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
