# Privacy retention and encryption-key rotation

## Purpose

Limit how long operational and private import data survives, reliably remove
unreferenced objects, and rotate encryption keys without making existing
ciphertext unreadable.

## User-visible behavior

- Encrypted pasted text and correction notes are erased 24 hours after a
  terminal import.
- Terminal import jobs are retained for 30 days; provider-attempt accounting is
  retained for 90 days.
- Expired or revoked refresh-token hashes are removed after seven days.
- Expired negative caches are removed immediately. Invalid extraction caches
  and their orphaned thumbnails are removed after 30 days.
- Recipe sync history and tombstones are retained for 365 days. A device whose
  cursor predates retained history receives `syncResetRequired`; iOS restarts
  at cursor zero and reconciles a complete server snapshot instead of silently
  missing a deletion.
- Completed deletion audits retain only keyed digests and expire after 365
  days.
- Account-owned records remain until the user deletes the account. Permanent
  deletion is documented separately in `account-deletion.md`.

All periods are production settings, bounded by validation, and may be shortened
when policy requires it.

## Implementation

Celery Beat invokes `ladle.privacy.sweep` hourly. The task:

1. Deletes expired database records in a transaction.
2. Inserts object keys into `object_deletion_queue` before deleting cache rows.
3. Claims due object deletions with `FOR UPDATE SKIP LOCKED`.
4. Treats object deletion as idempotent, recording bounded exponential retry
   state on failure.

The bucket lifecycle in `deploy/object-storage-lifecycle.json` expires temporary
objects and incomplete uploads after one day and noncurrent object versions
after 30 days. Compose bucket initialization enables versioning and imports
this policy into local and Mac mini MinIO automatically. Apply the same policy
to every externally managed environment's private bucket before production.

## Managed encryption keys

Production requires:

- `LADLE_DATA_ENCRYPTION_ACTIVE_KEY_ID`, a stable identifier such as
  `2026-q3`.
- `LADLE_DATA_ENCRYPTION_KEYRING`, a JSON object supplied by the platform's
  secret manager, mapping key IDs to at least 32 characters of independent key
  material.
- A distinct keyring in development, staging, and production.

New `LPT2` envelopes authenticate and carry the key ID. Decryption selects that
exact key, so changing the active ID does not strand existing values. The
legacy `LPT1` key remains readable during migration.

### Normal rotation

1. Generate new random key material in the production secret manager.
2. Add it to the keyring under a new ID without removing old IDs.
3. Deploy and verify readiness plus a private-import round trip.
4. Change the active ID and deploy again.
5. Keep old IDs for at least the longest ciphertext lifetime plus the backup
   retention window. Remove an old ID only after a database query proves no
   envelope references it.

### Emergency rotation

If key material may be exposed, disable sensitive imports, add and activate a
new key immediately, revoke access to the old secret, and run a controlled
reencryption job before removing the compromised ID. Preserve the old material
only in a tightly scoped break-glass secret until all live and restorable backup
ciphertext has been reencrypted or expired. Record the incident and verify Apple
refresh-token revocation remains possible before resuming account deletion.

## Affected components

- `ladle/privacy/retention.py`
- `ladle/crypto/private_text.py`
- worker Beat/runtime wiring
- migration `0011`
- iOS sync recovery and privacy disclosure
- object-storage lifecycle deployment policy

## Verification

- Integration coverage seeds each retained data class, runs a sweep, confirms
  the retained/current records remain, and processes an orphaned object.
- Crypto tests cover randomized encryption, key IDs, active-key rotation,
  legacy decryption, unknown IDs, and UTF-8 byte limits.
- Backend sync tests reject an expired cursor. iOS tests prove the client
  restarts from a snapshot and reconciles missing recipes.
- Apply the lifecycle policy in staging, create a temporary object and an
  incomplete multipart upload, and verify the provider expires both on its
  documented schedule.
