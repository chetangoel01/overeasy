# Import quotas and provider budget reservations

## Purpose

Guest recipe capacity is a library limit, not a cost control: an attacker can
create new guests, retry failed work, or fan requests across workers. Import
admission and provider dispatch therefore have independent, durable budgets.

## User-visible behavior

Every new submission and retry consumes one per-user quota event. Repeated
idempotent submissions do not consume another event. Daily and monthly windows
use UTC calendar boundaries and are enforced under a PostgreSQL user-row lock,
so concurrent API processes cannot oversubscribe them.

Admission over quota returns HTTP `429`, the typed `quotaExceeded` error, and a
`Retry-After` value for the applicable reset. A worker that reaches the global
provider budget marks the import terminal with failure reason
`quotaExceeded`; it does not leave the job in `parsing`. The iOS contract and
failure screens decode and explain that outcome.

## Atomic provider accounting

Before a billed provider call, `ProviderUsageLedger` locks the current budget
window and reserves a conservative configured estimate. Completed calls
atomically replace the reservation with actual billed units. Calls that fail
before incurring a charge release the reservation; failures after a known
charge reconcile that known amount. Idempotent ledger updates never reserve or
spend twice.

`provider_budget_windows` is the shared cross-worker source of truth.
`provider_attempts` records the reservation amount, window, and expiration for
audit and crash recovery. The window stores its configured maximum so spend
and outstanding reservations can be inspected together.

## Configuration

- `LADLE_USER_IMPORT_DAILY_QUOTA`
- `LADLE_USER_IMPORT_MONTHLY_QUOTA`
- `LADLE_PROVIDER_DAILY_BILLED_UNIT_LIMIT`
- `LADLE_PROVIDER_RESERVATION_BILLED_UNITS`
- `LADLE_PROVIDER_BUDGET_RESERVATION_MINUTES`

The monthly user quota must be at least the daily quota. Reservation lifetime
must remain longer than the maximum provider-call interval; startup timing
validation enforces the final production relationship.

## Verification

PostgreSQL integration tests race concurrent user admissions and concurrent
worker reservations. They verify exact-one admission, idempotent quota events,
daily/monthly reset boundaries, reservation release on failure, reconciliation
to actual usage, and rejection when spent plus in-flight reservations reaches
the budget. API and orchestrator tests cover the typed `429` and terminal
worker failure. Shared Swift contract tests cover the new failure value.
