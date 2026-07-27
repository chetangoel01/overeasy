# HTTP request-size limits

## Purpose

Bound memory and parser work before an untrusted request reaches authentication,
validation, or route code. This also keeps multibyte private import text within
the encryption layer's 200,000-byte plaintext ceiling.

## Behavior

- The API accepts at most `LADLE_MAXIMUM_REQUEST_BODY_BYTES` bytes per request;
  the default is 1 MiB.
- Both declared `Content-Length` and the bytes actually streamed are checked, so
  chunked requests and false length headers cannot bypass the limit.
- Oversized bodies receive HTTP `413` with the normal `invalidRequest` envelope.
- Empty or over-200,000-byte correction/pasted text is rejected during request
  validation, before encryption. Character limits remain as an additional UX
  bound.
- The public Nginx layer must include
  `deploy/nginx/request-size.conf`. Platforms with a managed ingress must set
  the equivalent 1 MiB request-body policy.
- The Mac mini profile applies the same values in its rootless edge
  configuration and returns the typed API error from Nginx itself, so an
  oversized request never reaches the unpublished API container.

The 1 MiB HTTP ceiling leaves room for JSON escaping of a 200,000-byte Unicode
private-text value plus the rest of an import or bounded recipe payload.

## Affected components

- `ladle.api.request_limits.RequestBodyLimitMiddleware`
- `ladle.api.app.create_app`
- `ladle.api.routes.imports`
- `ladle.crypto.private_text`
- `deploy/nginx/request-size.conf`

## Verification

`tests/unit/test_request_limits.py` covers declared and chunked overages, stream
replay, and UTF-8 byte alignment. Cipher boundary coverage lives in
`tests/unit/crypto/test_private_text.py`; the Nginx fragment is kept beside the
deployment configuration for operator review. The Mac profile test checks its
edge wiring and an executable container probe sends 1,048,577 bytes through
the local edge and requires typed HTTP 413.
