FROM nginx:1.30.4-alpine3.24-slim@sha256:ddde39c6e51f02fde7410c2e9c234cf2d0a4c7bdbbe176aeb37d8ad7ab4eb58c

# Same CVE-2026-14456 exposure as egress.Dockerfile: this image's Alpine 3.24
# layer ships libcrypto3/libssl3 at 3.5.7-r0 and the fix is published to the
# apk repository rather than baked into a newer base. Pinned to match the rest
# of this file; drop once a base image ships 3.5.8-r0 or later.
RUN apk add --no-cache \
        libcrypto3=3.5.8-r0 \
        libssl3=3.5.8-r0

COPY --chown=101:101 --chmod=0444 nginx.conf /etc/nginx/nginx.conf

ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
