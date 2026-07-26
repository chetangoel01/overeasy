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

## Infrastructure backstop

`deploy/kubernetes/worker-egress-network-policy.yaml` is a default-deny worker
policy. It permits DNS, explicitly labelled PostgreSQL/Redis/object-storage
pods, and public TCP/443 while excluding private, loopback, link-local,
multicast, reserved, documentation, benchmarking, metadata, and
IPv4-mapped-IPv6 ranges.

Before applying it, deployment manifests must use the documented worker and
dependency labels. Managed private dependencies outside the cluster require
explicit single-service CIDR rules; do not broaden the public rule. Platforms
without Kubernetes NetworkPolicy must reproduce the same rules in their
security group, firewall, or egress gateway. Deployment verification must
prove metadata and task-credential endpoints are unreachable from a worker.

## Verification

Unit tests cover mixed DNS answers, DNS rebinding, every redirect, literal
metadata endpoints, IPv4-mapped IPv6, nonstandard schemes and ports,
provider-returned subtitle/media/thumbnail URLs, byte bounds, and pinned
address/Host/SNI behavior. The exact staging worker still requires a live
egress probe before this control is considered deployed.
