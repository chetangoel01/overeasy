# Provider contracts

Accessed: 2026-07-26

These adapters use only documented server APIs. Recorded fixtures are
sanitized, contain no credentials or user data, and exercise the response
shapes listed below.

## Supadata

Official documentation:

- [API introduction](https://docs.supadata.ai/api-reference/introduction)
- [Metadata](https://docs.supadata.ai/get-metadata)
- [Transcript](https://docs.supadata.ai/get-transcript)
- [Structured video extraction](https://docs.supadata.ai/get-extract)
- [Extract job result](https://docs.supadata.ai/api-reference/endpoint/extract/extract-get)

Base URL: `https://api.supadata.ai/v1`

Authentication: `x-api-key` request header.

The metadata adapter uses `GET /metadata`. The transcript fallback makes one
`GET /transcript` request with `mode=auto`; Supadata defines that mode as a
native-caption lookup followed by generated transcription when captions are
absent. Calling `mode=native` immediately before `mode=auto` would repeat the
same native lookup and add a network, quota, and billing failure point without
adding coverage. A response may be immediate (`200`) or asynchronous (`202`
with `jobId`), followed by `GET /transcript/{jobId}`. Transcript offsets and
durations are milliseconds. The adapter records `x-billable-requests`.

Visual recipe evidence uses `POST /extract` with an explicit JSON Schema and
polls `GET /extract/{jobId}`. Supadata documents this endpoint as analysis of
what is seen and heard, distinct from its transcript and metadata endpoints.

Fixtures:

- `tests/fixtures/providers/supadata/metadata.json`
- `tests/fixtures/providers/supadata/transcript.json`
- `tests/fixtures/providers/supadata/extract-completed.json`

## SoScripted

Official documentation:

- [Video Transcription API](https://soscripted.com/transcript-api)

Base URL: `https://soscripted.com/api/public`

Authentication: `Authorization: Bearer …`.

The fallback adapter sends `POST /transcribe` with a supported social-video
URL. The documented JSON response is synchronous and contains
`caption.text` plus timestamped `caption.segments`. Status `402` is treated as
a quota circuit event; authentication, timeout, private/deleted, malformed,
and service failures remain distinct. The request timeout is ten minutes,
matching the provider's documented synchronous Python example; the previous
30-second default could abandon a healthy transcription before it completed.

Fixture:

- `tests/fixtures/providers/soscripted/transcript.json`

## Capability policy

The acquisition order is:

1. free platform metadata, captions, on-screen text, and linked recipe pages;
2. Whisper transcription of the acquired media when free evidence is thin;
3. one Supadata `mode=auto` URL transcript fallback;
4. SoScripted transcript on an independent Supadata transcript outage;
5. sampled-frame analysis, then Supadata structured visual analysis when the
   recipe still lacks quantities or actions;
6. explicitly enabled server media/OCR fallback if API evidence remains sparse.

Private/deleted observations stop the chain immediately. Authentication and
quota failures open the affected provider circuit. The server fallback is
disabled by default and is never an on-device iOS dependency.

## Transcript fallback verification

Purpose: keep TikTok and Instagram transcription resilient without maintaining
two sequential Supadata requests that implement the same native-first policy.

Affected components:

- `ladle/acquisition/provider_chain.py`
- `ladle/config.py`
- `.env.example`
- `tests/unit/acquisition/test_provider_chain.py`
- `tests/unit/acquisition/test_free_chain.py`
- `tests/unit/test_config.py`

Verification on 2026-07-26:

- the focused provider/free-chain suite passed all 23 tests;
- the complete backend suite passed all 280 tests with three live-provider
  tests skipped when not explicitly selected;
- a live `mode=auto` call for TikTok video `7628226554589482271` returned 11
  timestamped segments and 478 characters;
- a live forced-generation probe of the same TikTok source returned six
  segments, confirming both automatic and forced generated transcription are
  accepted for the platform;
- a live `mode=generate` probe for Instagram reel `Ct-OnLxJlxw` and a
  `mode=auto` probe for `Cx8pqZDv7G0` returned `TranscriptUnavailable`, while
  raw-media Whisper had already succeeded for both. Supadata is therefore a
  useful TikTok/URL fallback, not the sole Instagram recovery path; SoScripted
  must have credits for an independent URL-based Instagram fallback.

An empty transcript remains a valid outcome for a music-only video. It falls
through to visual evidence rather than being retried as though another speech
recognizer could recover speech that is not present.
