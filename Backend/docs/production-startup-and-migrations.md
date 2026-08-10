# Production startup and migrations

Production refuses to start with placeholder secrets, incomplete Apple/Google
OAuth, disabled App Attest, a fake extraction provider, or missing durable
dependencies.

The single-host VPS may use password-protected PostgreSQL, Redis, and MinIO over
its private Docker network. External service endpoints must still use TLS.
Distributed tracing is optional; structured logs, readiness, metrics, and rate
limits remain enabled.

`deploy/vps/manage.sh deploy` keeps startup ordering direct:

1. Validate the Compose file and production `Settings`.
2. Build the application image.
3. Start PostgreSQL, Redis, and MinIO.
4. Initialize the private bucket and run the one-shot Alembic migration.
5. Start the API and worker.
6. Require API readiness and a Celery worker ping.

The API checks migration revision `0012`, database, Redis roles, MinIO, worker,
and configuration. A failed build, configuration check, or migration leaves the
previous containers running. Rollback redeploys a known-good Git revision;
database downgrades require explicit compatibility review.
