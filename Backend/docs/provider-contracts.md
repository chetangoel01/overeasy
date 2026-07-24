# Provider contracts

Accessed: 2026-07-23

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

The metadata adapter uses `GET /metadata`. The transcript adapter uses
`GET /transcript` with `mode=native` first; when needed it uses `mode=auto`.
A response may be immediate (`200`) or asynchronous (`202` with `jobId`),
followed by `GET /transcript/{jobId}`. Transcript offsets and durations are
milliseconds. The adapter records `x-billable-requests`.

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
and service failures remain distinct.

Fixture:

- `tests/fixtures/providers/soscripted/transcript.json`

## Capability policy

The acquisition order is:

1. Supadata public metadata and `mode=native` transcript;
2. deterministic recipe coverage check;
3. Supadata `mode=auto` transcript when native speech is absent;
4. SoScripted transcript on an independent Supadata transcript outage;
5. Supadata structured visual analysis for missing quantities or actions;
6. explicitly enabled server media/OCR fallback if API evidence remains sparse.

Private/deleted observations stop the chain immediately. Authentication and
quota failures open the affected provider circuit. The server fallback is
disabled by default and is never an on-device iOS dependency.
