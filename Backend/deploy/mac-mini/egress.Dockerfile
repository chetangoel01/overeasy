FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# libcrypto3/libssl3 ship at 3.5.7-r0 in this base image, which carries
# CVE-2026-14456 (OpenSSL denial of service via unbounded memory). The fix is
# published to the v3.24 apk repository rather than baked into a newer image,
# so it is pulled in explicitly here. Versions stay pinned to match the rest of
# this file; drop the openssl pins once a base image ships 3.5.8-r0 or later.
RUN apk add --no-cache \
        iptables=1.8.13-r0 \
        libcrypto3=3.5.8-r0 \
        libssl3=3.5.8-r0

COPY --chmod=0555 worker-egress.sh /usr/local/bin/worker-egress

ENTRYPOINT ["/usr/local/bin/worker-egress"]
