# Account deletion

## Purpose

Give guest, Apple, and Google users an authenticated, idempotent way to
permanently remove their account and associated data.

## User-visible behavior

The app presents a destructive confirmation and keeps its progress indicator
visible while deletion runs. The API additionally requires the literal
confirmation `DELETE` and the current session refresh token. Local credentials
and recipes are cleared only after the server returns success.

Apple accounts have their stored Sign in with Apple refresh token revoked before
database deletion. A revocation failure leaves the account intact for retry.
Google identity rows and guest installations are deleted by the same flow.

## Data removal

Deleting the user cascades through recipes and their graph, import jobs,
sessions and refresh-token hashes, devices and App Attest keys, Apple or Google
identity, import quotas and capacity reservations, provider attempts, private
correction/paste text, and sync state/history. User-owned object keys are copied
to `object_deletion_queue` before the cascade, so storage failure cannot restore
or block the account.

The only retained record is `account_deletion_audits`: a deletion UUID,
account kind, status, timestamps, failure class if any, and keyed one-way
digests of the former user and idempotency key. It contains no raw user,
installation, recipe, provider credential, or private-text data.

## Idempotency and progress

The iOS client derives one stable deletion idempotency key from its remote user
ID and reuses it on retry. If the successful response is lost, the still-valid
signed access token and the same key can retrieve the completed audit receipt
even though the session row has already been deleted. Successful responses
include `X-Deletion-ID` and `X-Deletion-Status: completed`.

The durable audit moves through `requested`, `revokingProvider`, `deleting`,
`completed`, or `failed`, providing an operational progress and audit trail
without retaining account identity.

## Affected components

- `alembic/versions/0010_add_account_deletion_audit.py`
- `ladle/auth/deletion.py`
- `ladle/auth/sessions.py`
- `ladle/api/routes/auth.py`
- `Ladle/Account/AuthClient.swift`
- `Ladle/Account/AccountSheet.swift`

## Verification

Backend tests cover confirmation, refresh-token reauthentication, response-loss
idempotency, Apple revocation, guest/Apple/Google deletion, relational cascades,
private audit data, and storage cleanup queueing. The iOS AuthClient test
verifies the reauthentication and deterministic idempotency payload and that
local state clears only after the server succeeds.
