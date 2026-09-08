# Import worker reliability

## Purpose

Keep one worker in control of a shared extraction while slow acquisition and
model calls run, and make task, broker, and database recovery clocks agree.

## User-visible behavior

An import can spend several minutes acquiring text, transcribing audio,
extracting a recipe, and enriching nutrition without another worker taking over a
healthy claim. A worker that exceeds its hard runtime is killed before Redis
makes the same message visible again, and maintenance does not call that job
stale while the task can still be alive.

## Decisions

- A daemon heartbeat thread uses a fresh database session every 30 seconds.
  The monitor surrounds acquisition, transcription, extraction, nutrition,
  verification, and thumbnail storage. Images are for display only.
- Heartbeat failure is surfaced before the worker commits a result, preserving
  the existing claim-version fence.
- The default claim is ten minutes, more than twice the maximum heartbeat gap.
- Celery soft and hard limits are 25 and 26 minutes. Redis visibility is 30
  minutes, stale-job detection is 32 minutes, recipe reservations are 60
  minutes, and provider budget reservations are 30 minutes.
- Workers prefetch one late-acknowledged task and retry broker connection during
  startup.
- Only explicit transient task failures—timeouts, lost connections, Redis or
  broker failures, transient database errors, provider transport failures, and
  lost claims—retry three times with bounded exponential backoff and jitter.
  Validation and invariant failures enter the terminal dead-letter path
  immediately instead of repeating work that cannot recover without a code or
  data change.
- Orchestration and Celery share the retry classifier in
  `ladle/imports/failures.py`, including transport errors wrapped by a provider.
  A failed attempt releases only its own version of the extraction claim,
  including when completion fails, so its retry can lead immediately. While
  retrying, jobs remain `parsing`, reserved capacity stays reserved, and private
  correction text remains available. Exhaustion follows the existing
  [dead-letter path](import-dispatch-recovery.md).
- Acquisition continues through independent fallbacks after a transient error.
  If the resulting text passes the recipe evidence gate, the import proceeds.
  Otherwise the transient error reaches Celery rather than being mislabeled
  `insufficientTextEvidence`. An open provider circuit is also retryable. A
  genuinely sparse response with no transient outage still reaches the normal
  evidence rejection; this does not loosen the extraction gate.
- Provider circuit failures are counted atomically in Redis, so an outage opens
  one shared circuit instead of one independent circuit per worker process.
- Configuration validation rejects any timing combination that violates this
  ordering or lets a provider timeout outlive the soft task limit.

## Affected components

- `ladle/imports/heartbeat.py`
- `ladle/imports/orchestrator.py`
- `ladle/imports/failures.py`
- `ladle/acquisition/provider_chain.py`
- `ladle/imports/outbox.py`
- `ladle/worker/runtime.py`
- `ladle/worker/app.py`
- `ladle/usage/circuit.py`
- `ladle/config.py`

## Verification

Unit tests cover periodic renewal, lost-claim propagation, the transient
failure allowlist, task configuration, and invalid timing combinations. The
end-to-end worker test proves that the production orchestration path installs a
monitor around a leader extraction.

September 8 recovery regressions were observed failing before the fix. They
exercise transient errors at all six acquisition rungs, a successful fallback,
an open circuit during public recheck, and immediate successful retries after
acquisition, wrapped extraction, completion, public-recheck, and private-reparse
failures. The focused acquisition/reparse run passed 63 tests.
