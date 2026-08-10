# Test the recipe pipeline with Swagger

Ladle exposes an interactive Swagger UI only in the development environment.
It is generated directly from the FastAPI routes, so it stays aligned with the
request and response models instead of becoming a second API contract.

## Start Swagger

From `Backend/`:

```bash
LADLE_WORKER_PROVIDER_MODE=fake docker compose up -d --build
open http://127.0.0.1:4112/docs
```

The raw OpenAPI 3.1 document remains available at
`http://127.0.0.1:4112/openapi.json`. Production and test processes do not
register `/docs`, and the public gateway also hides the OpenAPI endpoint.

The explicit override guarantees the deterministic fake provider even when a
private `Backend/.env` normally enables live providers. Requests still travel
through FastAPI, PostgreSQL, Redis, Celery, the import state machine, recipe
persistence, and sync, but they do not call paid extraction services.

## Run the numbered pipeline

Swagger marks the core journey with `x-ladle-test-step` and explains each step
in the operation description.

1. Execute `POST /v1/auth/guest` with the `localGuest` example. Copy the
   returned `accessToken`.
2. Select **Authorize** at the top of Swagger. Paste the token value only; do
   not add the `Bearer` prefix yourself.
3. Execute `POST /v1/imports` with the `videoImport` example. Replace `jobID`
   and `idempotencyKey` with the same fresh lowercase UUID when you want a new
   run. Save the returned `jobID`.
4. Execute `GET /v1/imports/{job_id}` until `status` becomes `ready`,
   `needsReview`, or `failed`. Successful terminal jobs include `recipeID`.
5. Execute `GET /v1/recipes/{recipe_id}` with that recipe ID to inspect the
   persisted graph.
6. Execute `GET /v1/recipes/sync` with `cursor=0` and `limit=100`. Save
   `nextCursor` for the next incremental poll.

Reusing the same `(user, idempotencyKey)` returns the original job. A fresh
pipeline run therefore needs a fresh UUID. Reusing the same source URL with
`allowDuplicate=false` may correctly return `duplicateRecipe`; use a different
guest session, change the demo video ID, or deliberately enable duplicates.

## Exercise alternate evidence and retry

The `pastedText` import example bypasses acquisition and the shared public
cache while still exercising private-text encryption, extraction, persistence,
and sync. The current API still requires a valid `sourceURL` alongside pasted
text.

For a retry, execute `POST /v1/imports/{job_id}/retry` with the
`correctAndRetry` example, then poll the same job ID again. Retry is valid only
when the current job state permits it; otherwise the API returns `409`.

## Test OAuth

Apple and Google operations use the bearer token from the guest step because
sign-in merges that guest into the provider account.

- Apple requires a real identity token, its single-use authorization code, and
  the original raw nonce whose SHA-256 digest is in the identity token.
- Google requires an identity token whose audience is the configured Web/server
  OAuth client ID.

The default local Compose profile does not inject provider credentials, so
these operations return `503` until a private development override enables the
provider. Never paste production provider secrets into Swagger or commit them.

## App Attest boundary

The local Compose profile has App Attest enforcement disabled. Leave the six
`X-App-Attest-*` fields empty for local pipeline testing.

Production import and retry requests require all six fields. Swagger documents
them, but it cannot create a valid assertion: the assertion must come from a
signed physical Apple device and bind the exact HTTP method, path, and SHA-256
of the exact JSON bytes sent. Use the iOS client or the real-device App Attest
test for that portion of the production journey.

## Common failures

| Status | Meaning while testing |
| --- | --- |
| `401` | The Swagger bearer token is missing, expired, or revoked. |
| `403` | App Attest is enforced and the assertion fields are absent or invalid. |
| `409` | Duplicate recipe, guest recipe limit, invalid retry state, or sync conflict. |
| `422` | The URL, UUID, JSON field names, or payload shape is invalid. |
| `429` | A request or import quota was reached; inspect `Retry-After`. |
| `503` | OAuth is not configured, or a required dependency is not ready. |

Use lower-camel-case JSON with uppercase acronyms such as `jobID`, `sourceURL`,
and `recipeID`. UUIDs must be lowercase and hyphenated. Decimal recipe fields
are JSON strings, not numbers.

## Change record and verification

This guide accompanies the development-only Swagger route and the generated
OpenAPI enrichment in `ladle/api/openapi.py`. A focused schema test protects the
bearer security scheme, numbered import example, environment boundary, and App
Attest headers.

Verification on 2026-08-09 included Ruff, strict mypy, the repository secret
scan, 504 non-live/non-chaos tests, and a real local Compose journey from guest
creation through a ready fake-provider import, recipe fetch, and sync change.
