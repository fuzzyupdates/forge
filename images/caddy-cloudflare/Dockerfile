# images/caddy-cloudflare/Dockerfile
# Define the version globally. Defaulting to 2.11 for 2026 stability.
ARG CADDY_VERSION=2.11.3

# Stage 1: Build
FROM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_VERSION
# We use v${CADDY_VERSION} to ensure xcaddy gets the proper git tag format
RUN xcaddy build v${CADDY_VERSION} \
    --with github.com/caddy-dns/cloudflare \
    --output /usr/bin/caddy

# Stage 2: Final Image
FROM caddy:${CADDY_VERSION}-alpine

# OCI Labels link the image to your public 'forge' repo
LABEL org.opencontainers.image.source="https://github.com/fuzzyupdates/forge"
LABEL org.opencontainers.image.description="Custom Caddy image with Cloudflare DNS challenge support"
LABEL org.opencontainers.image.licenses="Apache-2.0"

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
