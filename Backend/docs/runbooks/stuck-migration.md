# Stuck migration

1. Do not start new API/worker versions. Read the one-shot Compose service logs, PostgreSQL
   locks, statement age, and `alembic_version`; never run a second upgrader.
2. If the statement is progressing within its deadline, wait. If blocked,
   identify and drain the blocking old application transaction before
   cancellation.
3. Roll back the application only when the prior version is compatible with the
   current partially/fully expanded schema. Never edit `alembic_version`
   manually.
4. For an irreversible failed migration, restore the latest verified dump into
   isolation and use the database-failover runbook. Otherwise fix forward with
   a reviewed, idempotent migration.
5. Rerun `alembic upgrade head` once, `alembic check`, metadata consistency,
   and readiness. Canary API and worker before the rollout resumes.
