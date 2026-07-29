# VPS Transcription and Thumbnail Context Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable VPS audio transcription, keep video-frame analysis disabled, and add one best-effort thumbnail observation before recipe extraction.

**Architecture:** The existing OpenRouter Whisper rung becomes usable by installing `ffmpeg` and enabling it in the VPS profile. Thumbnail bytes are fetched through the existing SSRF-safe thumbnail path, described by a thumbnail-specific method on the vision observer, added to `AcquiredVideoContext`, and then reused for recipe-card storage after extraction. Thumbnail analysis has its own setting and cannot invoke `FrameSampler`.

**Tech Stack:** Python 3.12, Pydantic settings, httpx, PostgreSQL provider ledger, Celery worker, Docker Compose, pytest.

---

### Task 1: Make the VPS runtime contract explicit

**Files:**
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Modify: `Backend/deploy/vps/docker-compose.yml`
- Modify: `Backend/ladle/config.py`
- Modify: `Backend/.env.example`

**Step 1: Write the failing profile test**

Update `test_vps_profile_keeps_state_private_and_bounded` and the reusable-build assertion to require:

```python
assert profile["x-vps-runtime-build"]["args"]["INSTALL_MEDIA_TOOLS"] == "true"
assert environment["LADLE_AUDIO_TRANSCRIPTION_ENABLED"] == "true"
assert environment["LADLE_FRAME_ANALYSIS_ENABLED"] == "false"
assert environment["LADLE_THUMBNAIL_ANALYSIS_ENABLED"] == "true"
```

Keep `LADLE_SERVER_MEDIA_FALLBACK_ENABLED=false`.

**Step 2: Run the test to verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/deploy/test_vps_profile.py::test_vps_profile_keeps_state_private_and_bounded \
  tests/unit/deploy/test_vps_profile.py::test_vps_profile_installs_media_tools_in_python_images
```

Expected: failures showing media tools and audio transcription are still
disabled and the thumbnail setting is absent.

**Step 3: Implement the minimal profile and setting**

- Set `INSTALL_MEDIA_TOOLS: "true"`.
- Set `LADLE_AUDIO_TRANSCRIPTION_ENABLED: "true"`.
- Keep `LADLE_FRAME_ANALYSIS_ENABLED: "false"`.
- Add `LADLE_THUMBNAIL_ANALYSIS_ENABLED: "true"`.
- Add `thumbnail_analysis_enabled: bool = False` to `Settings`.
- Document the environment setting in `.env.example`.

**Step 4: Run the focused profile tests to verify green**

Run the command from Step 2.

Expected: both tests pass.

### Task 2: Split safe thumbnail download from storage

**Files:**
- Modify: `Backend/tests/unit/imports/test_thumbnail_ssrf.py`
- Modify: `Backend/ladle/imports/thumbnails.py`

**Step 1: Write the failing download/reuse tests**

Add tests proving that:

```python
asset = fetcher.download(source, candidate_url="https://images.example/recipe.jpg")
assert asset is not None
assert asset.data == b"thumbnail-bytes"
assert asset.content_type == "image/jpeg"

key = fetcher.store(source, asset)
assert storage.puts[0][1:] == (b"thumbnail-bytes", "image/jpeg")
```

Retain the existing SSRF test and assert an unsafe resolved thumbnail never
produces an asset.

**Step 2: Run the thumbnail test to verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/imports/test_thumbnail_ssrf.py
```

Expected: failure because `download`, `store`, and `ThumbnailAsset` do not yet
exist.

**Step 3: Implement the minimal asset API**

Add an immutable `ThumbnailAsset` containing bytes, content type, and
extension. Refactor `OEmbedThumbnailFetcher` so:

- `download` performs URL resolution, pinned safe download, size checking,
  and content-type validation;
- `store` writes an already validated asset to object storage;
- `fetch` remains backward compatible by calling `download` then `store`;
- all failures remain best-effort and return `None`.

**Step 4: Run the thumbnail test to verify green**

Run the command from Step 2.

Expected: all thumbnail SSRF tests pass.

### Task 3: Add thumbnail-specific vision observation

**Files:**
- Modify: `Backend/tests/unit/acquisition/test_vision.py`
- Modify: `Backend/ladle/acquisition/vision.py`

**Step 1: Write the failing observer tests**

Add tests proving `VisionObserver.observe_thumbnail`:

- sends exactly one image;
- uses a prompt that calls it a thumbnail, not a sequence of video frames;
- returns `VisualEvidence` with no timestamp;
- uses `thumbnail-vision:<model>` provenance;
- records a distinct `thumbnailVision` / `thumbnailVisual` provider attempt;
- rejects an empty or unusable response as `VisualAnalysisUnavailable`.

**Step 2: Run the focused tests to verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/acquisition/test_vision.py::test_thumbnail_becomes_one_untimed_observation \
  tests/unit/acquisition/test_vision.py::test_empty_thumbnail_observation_is_unavailable
```

Expected: failure because the thumbnail method is absent.

**Step 3: Implement the minimal observer method**

Refactor the observer request/parsing helper only as far as needed to support:

```python
observer.observe_thumbnail(
    asset,
    job_id=job_id,
    source_revision=source.source_revision,
)
```

Use a thumbnail-specific instruction limited to visible dish appearance,
visible ingredients, and verbatim visible text. It must forbid inferred
cooking steps. Do not call `FrameSampler`.

**Step 4: Run the full vision unit file to verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/acquisition/test_vision.py
```

Expected: all tests pass.

### Task 4: Enrich extraction context without making thumbnails fatal

**Files:**
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`
- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/worker/runtime.py`

**Step 1: Write the failing orchestration tests**

Extend the retry integration fixture with fake thumbnail fetcher and observer
objects. Add tests proving:

- an available thumbnail observation is present in `FakeExtractor.calls[-1]`;
- its asset is stored for a normal shared extraction without a second
  download;
- a retry/bypass extraction still receives thumbnail context;
- `VisualAnalysisUnavailable` appends
  `thumbnailAnalysisUnavailable` and extraction continues;
- successful analysis appends `thumbnailAnalysisUsed`.

**Step 2: Run the focused integration tests to verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/integration/imports/test_retry_reparse.py
```

Expected: failures because the orchestrator has no thumbnail observer stage.

**Step 3: Implement minimal orchestration**

- Add an optional thumbnail-observer protocol/constructor dependency.
- Download the thumbnail after acquisition and before extraction.
- Call thumbnail observation when enabled and an asset exists.
- Append observations and diagnostics to the mutable acquisition context.
- Continue on `ProviderUnavailable`.
- Store the same asset after successful shared extraction.
- Preserve the existing no-cache/no-new-thumbnail behavior for private
  completion while still allowing the public thumbnail to inform extraction.

Wire the observer in `build_worker_runtime` only when
`thumbnail_analysis_enabled` and the OpenRouter key are present. Keep
`_vision_provider` and `FrameSampler` controlled solely by
`frame_analysis_enabled`.

**Step 4: Run focused integration and worker tests to verify green**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/integration/imports/test_retry_reparse.py \
  tests/unit/acquisition/test_vision.py \
  tests/unit/imports/test_thumbnail_ssrf.py
```

Expected: all tests pass.

### Task 5: Verify the backend change and document it

**Files:**
- Modify: `docs/verification/2026-07-28-vps-staging.md`
- Modify: `docs/plans/2026-07-28-vps-staging-production.md`

**Step 1: Update companion documentation**

Record:

- why the first rollout disabled transcription;
- audio transcription is now enabled;
- frame sampling remains disabled;
- thumbnail analysis is a distinct single-image, best-effort rung;
- exact tests and live verification results.

**Step 2: Run the backend verification suite**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/deploy/test_vps_profile.py \
  tests/unit/deploy/test_container_hardening.py \
  tests/unit/acquisition/test_audio.py \
  tests/unit/acquisition/test_vision.py \
  tests/unit/acquisition/test_provider_chain.py \
  tests/unit/imports/test_thumbnail_ssrf.py \
  tests/integration/imports/test_retry_reparse.py
uv run ruff check ladle tests
uv run mypy ladle
```

Run:

```bash
git diff --check
```

Expected: all commands exit zero.

**Step 3: Commit the verified implementation**

Stage only the files in this plan and commit:

```bash
git commit -m "feat: enable VPS transcript acquisition"
```

### Task 6: Deploy and prove the real import path

**Files:**
- Modify after evidence: `docs/verification/2026-07-28-vps-staging.md`

**Step 1: Push and deploy the exact commit**

Use the repository VPS push/deploy workflow so the active release revision
matches the local commit. Do not print provider secrets.

**Step 2: Run production health checks**

Run the external verifier and `sudo ladle-operations health`.

Expected: both report healthy.

**Step 3: Retry the latest stuffed-pepper import**

Retry job `ca9be246-8cf7-493f-b17b-96a7a6d13b61` through the supported API/app
retry path. Its existing current recipe causes retry to bypass the shared
cache.

**Step 4: Verify provider and recipe evidence**

Query only sanitized fields. Confirm:

- a completed `openrouter` transcript attempt using Whisper;
- no frame-analysis provider attempt;
- a completed thumbnail-visual attempt if the source exposes a usable
  thumbnail, otherwise the explicit unavailable diagnostic;
- a completed structured extraction attempt;
- recipe steps are no longer all marked as inferred because transcript and
  observations were absent.

**Step 5: Record evidence and commit the verification update**

Update the verification document with job ID, timestamps, sanitized provider
operations, recipe evidence counts, and health results. Run
`git diff --check`, then commit:

```bash
git commit -m "docs: verify VPS transcript acquisition"
```
