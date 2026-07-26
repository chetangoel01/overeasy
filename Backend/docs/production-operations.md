# Production data-service operations

## Purpose

Define recoverable PostgreSQL and Redis service contracts, prove restoration,
and give operators deterministic incident procedures.

## Required service configuration

`deploy/operations/production-data-services.json` is a release gate, not a
suggestion. Production provisioning must supply evidence for every field:

- PostgreSQL 16+, multi-AZ, encrypted daily backups retained 35 days,
  cross-region backup copies, and continuous PITR with at least a seven-day
  window.
- PostgreSQL RPO at most five minutes and RTO at most 60 minutes.
- A successful isolated restore drill no more than 90 days old.
- Redis 7+, multi-AZ automatic failover, AOF with `appendfsync everysec`,
  hourly snapshots, `noeviction`, and refusal to accept writes when persistence
  fails.

The local Redis service uses the same AOF, snapshot, no-eviction, and
stop-on-persistence-error settings. Celery publishes persistent messages.
If Redis still loses queued messages, PostgreSQL's transactional outbox and
abandoned-job sweep redispatch committed imports; Redis is never the sole
record that work exists.

## Backup and restore

Backups must be encrypted with a production-only managed key, access-logged,
and restoreable into an isolated account/network. Never test a restore over the
live database.

`scripts/restore_drill.py` starts two real PostgreSQL 16 servers, seeds the
source, streams a custom-format `pg_dump` into an empty target with
`pg_restore --exit-on-error`, and compares ordered row checksums and server
versions. CI runs the same drill. The quarterly managed-service drill adds:

1. Restore the selected automated backup or PITR timestamp into isolation.
2. Run migrations only if the restored revision is older than the deployed
   application.
3. Verify row counts, representative checksums, foreign keys, account deletion
   absence, and object references.
4. Run read-only API acceptance checks against the restored endpoint.
5. Record actual RPO/RTO, backup identifier, operator, result, and cleanup.
6. Destroy the isolated restore after evidence is retained.

## Runbooks

- `runbooks/provider-outage.md`
- `runbooks/redis-loss.md`
- `runbooks/database-failover.md`
- `runbooks/secret-rotation.md`
- `runbooks/runaway-spending.md`
- `runbooks/stuck-migration.md`
- `runbooks/worker-rollback.md`
- `runbooks/account-deletion.md`

## Verification

- Manifest tests enforce the backup/PITR and Redis contract.
- Worker tests require persistent Celery delivery.
- The automated real restore drill proves dump/restore compatibility and data
  equality.
- A managed-provider restore and failover remain staging deployment gates; the
  local drill cannot prove a provider control plane or cross-region copy.
