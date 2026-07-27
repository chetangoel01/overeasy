FROM nginx:1.30.4-alpine3.24-slim@sha256:ddde39c6e51f02fde7410c2e9c234cf2d0a4c7bdbbe176aeb37d8ad7ab4eb58c

COPY --chown=101:101 --chmod=0444 nginx.conf /etc/nginx/nginx.conf

ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
