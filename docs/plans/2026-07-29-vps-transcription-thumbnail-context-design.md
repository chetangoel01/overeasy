# VPS Transcription and Thumbnail Context Design

## Purpose

The VPS currently performs live structured recipe extraction but its staging
profile disables the media tools and audio-transcription rung. When free
captions are unavailable, extraction therefore receives only post metadata and
can reconstruct an unusably sparse recipe. The same profile disables frame
analysis, which should remain disabled.

This change enables server-side audio transcription and adds one
thumbnail-only visual observation. It does not download or sample video frames
for visual analysis.

## User-visible behavior

- When native or generated captions do not provide a transcript, the worker
  downloads the public media audio, converts it with `ffmpeg`, and transcribes
  it through the configured OpenRouter Whisper model.
- When a public thumbnail is available, the worker may ask the configured
  vision model for a short description of only the visible dish, ingredients,
  and text. That observation is supplied to recipe extraction as supporting
  context.
- Missing or failed thumbnail analysis does not fail the import. Extraction
  continues with the transcript and other available evidence.
- Multi-frame video sampling remains disabled on the VPS.
- Retrying the affected stuffed-pepper import bypasses its existing weak cache
  entry so the new evidence can replace the inferred result.

## Architecture

### Audio transcription

The VPS runtime image will install the existing pinned `ffmpeg` package and set
`LADLE_AUDIO_TRANSCRIPTION_ENABLED=true`. The existing acquisition chain keeps
its current order: free captions first, then OpenRouter Whisper on the public
media audio, followed by any configured transcript-provider fallbacks.

`LADLE_FRAME_ANALYSIS_ENABLED` remains `false`, so enabling the media tools
does not activate frame sampling.

Some public media CDNs require the short-lived cookie jar and request headers
created during yt-dlp metadata discovery. Those values remain in memory only
and are forwarded through the same bounded, DNS-pinned media downloader.
Credential headers are removed if a download redirects to a different host.

### Thumbnail-only context

Thumbnail analysis will have its own configuration switch rather than reusing
the frame-analysis switch. The acquisition layer will safely download at most
one validated public thumbnail and send that image to the existing
OpenRouter-compatible vision observer with a thumbnail-specific instruction.
The result becomes `VisualEvidence` with thumbnail-specific provenance and no
video timestamp.

The thumbnail path will not invoke `FrameSampler`, fetch the video for visual
analysis, or claim that a thumbnail proves a cooking step. Its instruction
will limit output to visible dish appearance, visible ingredients, and
verbatim on-image text.

The existing thumbnail copy used by recipe cards remains best-effort. Shared
download logic should be reused where practical so SSRF checks, byte limits,
and supported content types stay consistent.

## Failure handling and cost

- Audio-transcription failures retain the existing diagnostic and fallback
  behavior.
- Thumbnail download, parsing, provider, and schema failures append a
  diagnostic and continue without visual context.
- Thumbnail analysis records one provider-usage attempt only when a valid
  thumbnail is actually sent to the vision provider.
- The VPS continues to perform zero multi-frame vision calls.
- Re-importing an existing recipe bypasses shared extraction cache even
  without correction notes, ensuring the newly enabled evidence path runs.

## Affected components

- VPS Compose build arguments and runtime environment.
- Runtime settings and provider construction.
- Thumbnail download/validation and thumbnail-only observation.
- Acquisition-chain context assembly and diagnostics.
- Bounded provider-metric labels for thumbnail analysis.
- Re-import state adopts the backend's replacement-candidate ID instead of
  rejecting it when it differs from the client's temporary placeholder.
- VPS profile, acquisition, vision, and runtime tests.
- VPS verification documentation.

## Verification

1. Add failing tests for the VPS profile: media tools installed, audio
   transcription enabled, frame analysis disabled, thumbnail analysis enabled.
2. Add failing tests proving exactly one thumbnail can produce untimed visual
   evidence and that thumbnail failure degrades to transcript-only extraction.
3. Run the focused unit tests through red, green, and refactor.
4. Run the complete VPS deployment test file and relevant acquisition,
   extraction, and worker tests.
5. Run `git diff --check` before commits.
6. Deploy the verified revision to the VPS and run its health verifier.
7. Retry the latest stuffed-pepper import with cache bypass.
8. Confirm the provider ledger contains a completed transcript attempt, no
   frame-analysis attempt, and a completed thumbnail-visual attempt when a
   thumbnail is available.
9. Confirm the resulting recipe contains transcript-backed detail rather than
   uncertainty stating that every step was inferred without transcript or
   observations.
