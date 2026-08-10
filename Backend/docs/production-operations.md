# Production data operations

Ladle uses one PostgreSQL container and one durable Redis container on its VPS.
This is enough for roughly 100 users and keeps recovery understandable.

PostgreSQL is the source of truth. Redis uses AOF with `appendfsync everysec`,
but the transactional import outbox can redispatch committed jobs after Redis
loss. Neither service publishes a host port.

`deploy/vps/manage.sh backup` creates a custom-format PostgreSQL dump, a MinIO
archive, and a SHA-256 manifest every night. Keep 14 local copies and copy them
to a second failure domain. The host-provider snapshot is useful but does not
replace the application-level dump.

At least quarterly, restore a selected dump into an isolated PostgreSQL 16
container, run integrity and representative API reads, record the result, and
remove the temporary database. CI's `scripts/restore_drill.py` continuously
checks basic dump/restore compatibility.

Use the focused runbooks under `docs/runbooks/` for provider, Redis, migration,
secret, spending, worker, and account-deletion failures. Add managed database
failover or point-in-time recovery only if measured usage or a stricter recovery
objective makes the additional service worthwhile.
