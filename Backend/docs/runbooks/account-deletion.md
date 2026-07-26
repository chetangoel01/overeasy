# Account deletion incident

1. Locate the request only by deletion ID, keyed user digest, and request ID.
   Never ask for recipe content, Apple identity token, or refresh token in logs
   or support messages.
2. If Apple revocation failed, leave the account intact in `failed` state,
   restore provider connectivity/credentials, and let the authenticated user
   retry the same idempotency key.
3. If database deletion completed but object cleanup is pending, keep the
   account deleted and repair `object_deletion_queue`; never recreate user rows.
4. Confirm recipes/imports/sessions/devices/identity/provider usage/private
   text/sync history are absent and unreferenced objects are deleted. Preserve
   only the pseudonymous deletion audit for its retention period.
5. A deleted account is not restored from backup. If a systemic defect affected
   multiple deletions, stop new deletion requests, retain audit evidence, page
   privacy/security owners, and notify affected users according to policy.
