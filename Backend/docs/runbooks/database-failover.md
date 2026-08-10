# PostgreSQL failover and restore

1. Stop `api` and `worker` if PostgreSQL is unavailable or consistency is
   uncertain. Preserve the failed volume until recovery is complete.
2. Select the newest verified custom-format dump and its matching MinIO archive
   from `/var/backups/ladle` or the off-host copy. Verify the SHA-256 manifest.
3. Restore the dump into an isolated PostgreSQL 16 container first. Check the
   Alembic revision, row counts, representative recipes, foreign keys, account
   deletions, and object references.
4. Replace the failed PostgreSQL volume only after the isolated restore passes.
   Restore MinIO only when its data is also missing or inconsistent.
5. Run `manage.sh deploy`, then `manage.sh health`. Verify session refresh,
   sync sequence monotonicity, outbox recovery, and one controlled import.

The single-host profile has no replica or automatic failover. Add a managed
database or point-in-time recovery when the product's measured recovery target
justifies the operational cost.
