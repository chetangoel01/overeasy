# App Attest enforcement

## Purpose and user-visible behavior

Production accepts guest creation and paid import submission/retry only from an
installed Ladle app with a server-verified Apple App Attest key. Development can
leave enforcement off so simulators and local API clients continue to work.
When enforcement is on, the iOS app obtains a one-time server challenge,
attests a Secure Enclave key during guest bootstrap, and sends a fresh,
request-bound assertion for each sensitive import mutation.

## Trust and replay decisions

- The server pins Apple's App Attestation Root CA and verifies the leaf and
  intermediate signatures, validity windows, nonce extension, P-256 key ID,
  App ID hash, environment AAGUID, zero attestation counter, and credential ID.
- Challenges are random, stored only as SHA-256 digests, bound to installation
  and purpose, expire after five minutes by default, and are consumed once.
- Assertion client data binds the challenge, installation, purpose, HTTP method,
  path, and SHA-256 of the exact transmitted JSON body.
- Assertion signatures use the stored attested public key. Counters must
  increase monotonically under a database row lock across API processes.
- A successful replacement-key attestation for a still-trusted installation
  atomically revokes its prior keys with the `keyRotated` reason. This permits
  intentional key rotation without leaving multiple active device keys.
- A bad signature or non-increasing counter revokes the key and marks its device
  revoked. Existing access and refresh tokens then fail, and the same
  installation ID cannot self-rehabilitate by attesting another key. Recovery
  requires an explicit trusted server-side re-enrollment or a new installation
  lifecycle.
- App Attest key IDs stay in the device-only Keychain. Account deletion removes
  the local key ID after the backend succeeds.

## Components and configuration

- `ladle/auth/attestation.py`: Apple cryptographic verifier and durable
  challenge/key lifecycle.
- `ladle/api/routes/attestation.py`: challenge issuance.
- `ladle/api/routes/auth.py` and `imports.py`: guest and sensitive-import
  enforcement.
- `Ladle/Account/AppAttestClient.swift`: device key, attestation, and assertions.
- Migration `0005`: `app_attest_challenges` and `app_attest_keys`.

Production must set:

```text
LADLE_ATTESTATION_ENFORCED=true
LADLE_APP_ATTEST_APP_ID_PREFIX=<App ID prefix from Apple Developer>
LADLE_APP_ATTEST_BUNDLE_ID=com.ladle.ios
LADLE_APP_ATTEST_ENVIRONMENT=production
```

The App ID prefix is not assumed to equal a Team ID; use the prefix shown for
the registered App ID in Apple Developer. Release entitlements select the
production App Attest environment, while Debug selects development.

## Verification

- Generated certificate-chain fixtures exercise valid attestation/assertion,
  wrong challenge, and signature tampering.
- PostgreSQL integration tests exercise expiry, one-time challenge consumption,
  installation binding, counter persistence, enforced API submission, atomic
  key rotation, durable installation revocation, and revoked-device refresh
  rejection.
- iOS tests exercise key attestation, challenge hashing, exact request-body
  binding, evidence encoding, and assertion headers.
- The signed real-device test intentionally revokes its installation and must
  run only against a disposable isolated database that is destroyed afterward.
  Apple's production attestation service is unavailable to the simulator, so a
  passing production-device run is still required before rollout.

Apple protocol reference: [Validating apps that connect to your
server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server).
