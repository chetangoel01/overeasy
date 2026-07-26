# PostgreSQL failover and restore

1. Put the API out of readiness and stop workers/Beat if the primary is
   unavailable or consistency is uncertain. Preserve the failed cluster.
2. Prefer managed multi-AZ failover. Confirm the promoted primary's timeline,
   replica lag/RPO, TLS endpoint, credentials, and current Alembic revision.
3. If failover is impossible, restore the latest safe backup or PITR point into
   an isolated cluster and follow `production-operations.md`.
4. Point a canary API/worker at the replacement, run read-only integrity and
   migration checks, then admit one fake/staging import before production
   traffic.
5. Re-enable Beat, workers, then API in that order. Verify outbox recovery,
   sessions, sync sequence monotonicity, object references, and deletion
   tombstones. Page if RPO exceeds five minutes or RTO approaches 60 minutes.
