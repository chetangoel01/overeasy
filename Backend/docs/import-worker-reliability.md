# Import worker reliability

## Purpose

Keep one worker in control of a shared extraction while slow acquisition and
model calls run, and make task, broker, and database recovery clocks agree.

## User-visible behavior

An import can spend several minutes acquiring media, transcribing audio,
analyzing frames, and extracting a recipe without another worker taking over a
healthy claim. A worker that exceeds its hard runtime is killed before Redis
makes the same message visible again, and maintenance does not call that job
stale while the task can still be alive.

## Decisions

- A daemon heartbeat thread uses a fresh database session every 30 seconds.
  The monitor surrounds the complete acquisition, transcription, vision,
  extraction, and thumbnail chain.
- Heartbeat failure is surfaced before the worker commits a result, preserving
  the existing claim-version fence.
- The default claim is ten minutes, more than twice the maximum heartbeat gap.
- Celery soft and hard limits are 25 and 26 minutes. Redis visibility is 30
  minutes, stale-job detection is 45 minutes, recipe reservations are 60
  minutes, and provider budget reservations are 30 minutes.
- Workers prefetch one late-acknowledged task and retry broker connection during
  startup.
- Configuration validation rejects any timing combination that violates this
  ordering or lets a provider timeout outlive the soft task limit.

## Affected components

- `ladle/imports/heartbeat.py`
- `ladle/imports/orchestrator.py`
- `ladle/worker/runtime.py`
- `ladle/worker/app.py`
- `ladle/config.py`

## Verification

Unit tests cover periodic renewal, lost-claim propagation, task configuration,
and invalid timing combinations. The end-to-end worker test proves that the
production orchestration path installs a monitor around a leader extraction.
