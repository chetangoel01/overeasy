# PostgreSQL restore drill — 2026-07-26

## Outcome

Passed. The automated drill created independent PostgreSQL 16 source and target
servers, inserted two probe rows, streamed a custom-format `pg_dump` into
`pg_restore --exit-on-error`, and verified:

- both rows were restored;
- ordered source and target SHA-256 checksums matched;
- source and restored server versions matched.

## Command

```bash
cd Backend
.venv/bin/pytest -q tests/integration/operations/test_restore_drill.py
```

Result: `1 passed in 3.30s`.

## Scope and next gate

This is a real engine-level restore and continuously tests dump compatibility.
It does not prove a future managed provider's backup control plane,
cross-region copy, PITR timestamp selection, IAM, or measured production RPO/RTO.
Repeat the procedure through the selected managed provider in staging before
deployment and at least quarterly; attach the provider backup identifier and
timings to the next record.
