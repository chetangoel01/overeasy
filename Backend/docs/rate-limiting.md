# Distributed request throttling

## Purpose

Public API instances share an atomic Redis token-bucket limiter so adding API
workers cannot multiply an attacker's allowance. Redis keys contain SHA-256
digests rather than raw user, device, installation, or IP identifiers.

## User-visible behavior

Rejected requests return HTTP `429`, a whole-second `Retry-After` header, and
the existing typed `rateLimited` error with an absolute `retryAt`. A request
must have capacity in every applicable bucket or none of its buckets are
consumed.

The limiter covers:

- guest creation by client IP and installation;
- refresh by client IP and device;
- Apple authentication by client IP and user;
- import submission and retry, independently, by IP, installation, and user;
- recipe mutation and sync polling by user; and
- a global per-minute emergency bucket across all API instances.

## Important decisions

Redis server time drives refill calculations, avoiding API-host clock skew.
Every multi-dimensional decision runs in one Lua script. All keys share a
Redis Cluster hash tag. The API fails closed if Redis errors rather than
silently disabling cost and abuse protection.

`X-Forwarded-For` is used only when the immediate peer belongs to
`LADLE_RATE_LIMIT_TRUSTED_PROXY_CIDRS`; otherwise the socket peer is the
identity. Production ingress CIDRs must be configured precisely.

## Affected components

- `ladle/api/rate_limits.py`
- auth, import, recipe, and sync routes
- the global API middleware and typed error handler
- `LADLE_RATE_LIMIT_*` settings

## Verification

The integration test runs two independent clients against a real Redis
container and proves shared capacity plus atomic multi-bucket rejection. Unit
tests cover trusted proxy resolution and policy dimensions. API tests verify
the `429` envelope and `Retry-After` header.
