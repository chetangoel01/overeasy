# Overeasy privacy policy

Effective: July 26, 2026

Overeasy turns public recipe links and text you provide into recipes and syncs
them across your devices. This policy describes the data needed to do that.
Overeasy does not sell personal data, serve ads, or track activity across other
apps or websites.

## Data we collect and why

- Account and device identifiers, authentication sessions, and App Attest
  security records provide sign-in, sync, fraud prevention, and replay defense.
  Apple or Google supplies its stable account identifier only when you choose
  that sign-in method.
- Imported URLs, public-source metadata, recipe content, thumbnails, and edit
  history provide imports and device sync.
- Pasted recipe text and correction notes are encrypted at rest and used only
  to complete or retry the requested import.
- Request IDs, pseudonymous user identifiers, import job IDs, provider stage,
  duration, result, rate-limit decisions, and error class support security,
  reliability, and cost control. Logs exclude recipe/private text,
  authorization tokens, provider credentials, and raw identity tokens.
- Apple Health receives nutrition only after you explicitly export it from the
  device. Timers and local notifications remain on the device.

## Service providers

Overeasy shares only data necessary to operate the selected feature:

- Hosting, managed PostgreSQL, Redis, and private object-storage providers
  process service data and backups.
- Depending on the successful import path, public URLs, captions, media
  evidence, pasted text, or correction notes may be processed by configured
  acquisition, transcription, vision, and extraction providers such as
  Supadata, SoScripted, OpenRouter, Anthropic, or their hosted model provider.
- Apple and Google process authentication when their respective sign-in option
  is used.

These processors act to provide Overeasy's service. Overeasy does not disclose
data to advertising or data-broker services.

## Retention

- Pasted text and correction notes: erased within 24 hours after an import
  reaches a terminal state.
- Completed or failed import jobs: 30 days.
- Provider-attempt and cost records: 90 days.
- Expired or revoked session and refresh-token hashes: seven days.
- Negative extraction caches: until their short expiry; invalid caches and
  orphaned thumbnails: 30 days before cleanup.
- Recipe sync changes and deletion tombstones: 365 days. A device returning
  after that window receives a fresh authoritative snapshot.
- Pseudonymous account-deletion audit records: 365 days.
- Recipes and account data: while the account exists, unless removed earlier at
  the user's request.
- Temporary object uploads: one day; noncurrent object versions: 30 days.

Encrypted automated backups are retained for 35 days; continuous
point-in-time recovery covers at least the latest seven days. Expired backups
are destroyed by the infrastructure provider's lifecycle.

## Account deletion

Every guest, Apple, and Google account can be permanently deleted in
**Account → Delete account**. The operation verifies the current session,
revokes Sign in with Apple credentials when applicable, and removes or
anonymizes recipes, imports, sessions, devices, identity links, provider usage,
private text, sync history, and unreferenced objects. It is idempotent so a
network retry cannot recreate or partially delete the account.

Deletion cannot be undone. Backups are not used to restore an individual
deleted account; any residual encrypted copy ages out within the 35-day backup
schedule.

## Security and changes

Private text uses authenticated, versioned encryption keys stored separately by
environment in managed secret storage. Traffic uses TLS, production access is
attested and rate limited, and workers are restricted from private-network and
cloud-metadata egress.

Material policy changes will update the effective date and the in-app
disclosure. A public support and privacy contact must be added before App Store
submission.
