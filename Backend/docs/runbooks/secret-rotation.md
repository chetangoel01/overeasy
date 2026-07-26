# Secret rotation

1. Identify the exact secret and affected services. Revoke exposed access and
   pause only operations that cannot safely run during rotation.
2. Add the replacement in managed secret storage, deploy consumers, verify
   readiness, then revoke the prior credential. Never commit or print either
   value.
3. JWT signing rotation invalidates current sessions unless a multi-key verifier
   is deployed first; announce forced sign-in. Redis/database/object-storage
   rotation must overlap old and new credentials during a canary.
4. Provider and Apple keys require a credential-gated staging check before
   production. Data-encryption keys follow the add/activate/reencrypt/remove
   procedure in `privacy-retention-and-key-rotation.md`.
5. Search formatter-redacted logs for authentication failures, confirm old
   credentials no longer work, record the key ID (never material), and close
   the incident only after dependent workers were replaced.
