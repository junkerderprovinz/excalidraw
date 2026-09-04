# syntax=docker/dockerfile:1
# =============================================================================
# excalidraw — a whiteboard that keeps to itself
#
# The upstream image is a plain nginx serving a built SPA, and that SPA talks to
# Excalidraw's own cloud: the shared-link store, the collaboration socket, the
# font CDN and an analytics script. None of that is configurable at runtime,
# because Vite bakes the URLs into the bundle at build time.
#
# This image takes the upstream build and points all of it back at itself:
#
#   - the shared-link store  -> /api/v2/scenes  (bundled storage backend)
#   - the collaboration socket -> the same origin (bundled room server)
#   - the fonts              -> served from this image, no CDN
#   - the analytics script   -> removed
#
# The API addresses become RELATIVE paths rather than an absolute URL built from
# some PUBLIC_URL variable. A relative path is resolved by the browser against
# whatever address the page was opened on, so the same image works on a LAN IP,
# behind a reverse proxy, under a subdomain, over HTTP or HTTPS, with no
# configuration at all. nginx routes those paths to the two node services inside
# the container.
#
# Why HTTPS is not optional: live collaboration calls crypto.subtle, which the
# browser only exposes in a secure context. Over plain HTTP on a LAN address
# window.isSecureContext is false, crypto.subtle is undefined, and starting a
# session dies with "Cannot read properties of undefined (reading 'generateKey')".
# Measured on 2026-09-05 against the upstream image. So this image serves HTTPS
# with a self-signed certificate it generates on first start, and keeps the plain
# HTTP port for the single-user case where no session is ever started.
# =============================================================================

ARG UPSTREAM_TAG=latest

# --- the upstream SPA, unmodified -------------------------------------------
FROM excalidraw/excalidraw:${UPSTREAM_TAG} AS web

# --- the store, ours ---------------------------------------------------------
# The usual self-hosted store is a Node service whose published image has not
# moved since February 2022. This one is a single static binary against SQLite,
# built here, with the same routes. See backend/main.go for what it keeps and why.
FROM golang:1.25-alpine AS store
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/excalidraw-store .

# --- the room server ---------------------------------------------------------
FROM excalidraw/excalidraw-room:latest AS room

# --- patch the SPA ----------------------------------------------------------
# Done at BUILD time, so the running container needs no network of its own and
# every start is identical.
FROM alpine:3.22 AS patch
RUN apk add --no-cache curl
COPY --from=web /usr/share/nginx/html /html
COPY rootfs/usr/local/bin/patch-spa.sh /patch-spa.sh
RUN sh /patch-spa.sh /html

# --- runtime ----------------------------------------------------------------
FROM node:24-alpine

RUN apk add --no-cache nginx openssl su-exec tini \
 && rm -f /etc/nginx/http.d/default.conf

COPY --from=patch /html /usr/share/nginx/html
COPY --from=store /out/excalidraw-store /usr/local/bin/excalidraw-store
COPY --from=room /excalidraw-room /opt/room
COPY rootfs/ /

ENV STORE_ADDR=127.0.0.1:8081 \
    STORE_DB=/config/store.sqlite \
    ROOM_PORT=8082 \
    TZ=Etc/UTC

EXPOSE 80 443
VOLUME ["/config"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start.sh"]
