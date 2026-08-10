# Outbound request and worker egress safety

## Purpose

Imports process URLs and provider-returned media, subtitle, thumbnail, oEmbed,
and linked-page locations. Those values must not become a route to cloud
metadata, task credentials, localhost, or private services.

## Application behavior

`PinnedHTTPClient` accepts HTTPS on port 443 only. It resolves the host once,
rejects the complete DNS answer if any address is non-global, and connects to
the validated address with the original `Host` and TLS SNI names. Every
redirect is resolved and checked independently. Responses are byte bounded.

The shared client now covers creator-linked pages, TikTok and yt-dlp subtitle
URLs, Instagram and yt-dlp media URLs, oEmbed calls, and returned thumbnails.
IPv4-mapped IPv6 is normalized before classification. Literal IPs, mixed DNS
answers, loopback, private, link-local, multicast, reserved, unspecified, and
cloud metadata targets are rejected.

yt-dlp is limited to metadata discovery on an already allowlisted canonical
social URL. It ignores local configuration and proxy environment variables.
It no longer downloads provider-returned subtitles or media; those bytes go
through the pinned client. Runtime `httpx` clients set `trust_env=False`.

## Deployment boundary

The VPS worker shares Ladle's private Compose network with PostgreSQL, Redis,
and MinIO and has ordinary public HTTPS access. There is no privileged firewall
sidecar. Security for user-controlled URLs stays in the application-level
pinned resolver described above, which is easier to test and maintain on one
host. The host firewall blocks all container origins from public access; shared
Caddy is the only web ingress.

If Ladle later moves to a multi-tenant cluster, add a platform-native egress
policy there rather than carrying a home-grown network namespace forward.

## Verification

Unit tests cover mixed DNS answers, DNS rebinding, every redirect, literal
metadata endpoints, IPv4-mapped IPv6, nonstandard schemes and ports,
provider-returned subtitle/media/thumbnail URLs, byte bounds, and pinned
address/Host/SNI behavior. The deployed worker should still be probed with
representative metadata, private-address, redirect, and public-HTTPS cases
before a release is promoted.
