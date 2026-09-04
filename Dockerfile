# syntax=docker/dockerfile:1
# =============================================================================
# excalidraw — a whiteboard that keeps to itself
#
# The published Excalidraw image is nginx over a built SPA, and that SPA talks
# to Excalidraw's own cloud: the shared-link store, the collaboration socket,
# the session scene in Google Firestore, a font CDN and an analytics script.
# None of it is configurable at runtime, because Vite bakes the addresses into
# the bundle when it is built.
#
# So this image builds the SPA itself and points every one of those back at the
# container:
#
#   shared links     -> /api/v2/scenes   (the store below)
#   session scene    -> /api/v2/rooms    (frontend/firebase.ts, replacing the
#                                         one file that talks to Firestore)
#   pasted images    -> /api/v2/files
#   collaboration    -> the page's own origin (the bundled room server)
#   fonts            -> served from this image
#   analytics        -> removed
#
# The API addresses are RELATIVE paths, not an absolute URL assembled from some
# PUBLIC_URL variable. The browser resolves a relative path against whatever
# address the page was opened on, so one image works on a LAN address, behind a
# reverse proxy, under a subdomain, over either protocol, with nothing to
# configure. nginx routes those paths to the two services inside the container.
#
# Why HTTPS is not optional here: live collaboration calls crypto.subtle, which
# a browser only exposes in a secure context. Over plain HTTP on a LAN address
# window.isSecureContext is false, crypto.subtle is undefined, and starting a
# session dies with "Cannot read properties of undefined (reading 'generateKey')".
# Measured against the published image on 2026-09-05. This image therefore
# serves HTTPS with a certificate it generates on first start, and keeps the
# plain HTTP port for the single-user case where no session is ever started.
# =============================================================================

# The upstream commit this image is built from. Pinned, never "main": a
# whiteboard that rebuilds into something different every night cannot be
# supported, and the frontend patch has to be re-checked whenever it moves.
ARG EXCALIDRAW_SHA=214cd6e6e8ac3ad6b68486aa7aa7241abdf9445f

# --- the SPA, built here -----------------------------------------------------
FROM node:24-alpine AS web
ARG EXCALIDRAW_SHA
RUN apk add --no-cache git python3 make g++
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/excalidraw/excalidraw.git \
 && git fetch -q --depth 1 origin "${EXCALIDRAW_SHA}" \
 && git checkout -q FETCH_HEAD
# The one file that talked to Firestore. Same six exports, same encryption,
# different destination — see its own header for what stays untouched and why.
COPY frontend/firebase.ts excalidraw-app/data/firebase.ts
# The "Export to Excalidraw+" card uploads to the commercial hosted product,
# which is the one thing this image exists to avoid. Replaced, not deleted:
# App.tsx imports both of its exports.
COPY frontend/ExportToExcalidrawPlus.tsx excalidraw-app/components/ExportToExcalidrawPlus.tsx
RUN yarn install --frozen-lockfile --network-timeout 600000
ENV VITE_APP_BACKEND_V2_GET_URL=/api/v2/scenes/ \
    VITE_APP_BACKEND_V2_POST_URL=/api/v2/scenes \
    VITE_APP_WS_SERVER_URL= \
    VITE_APP_ENABLE_TRACKING=false \
    VITE_APP_FIREBASE_CONFIG={} \
    NODE_OPTIONS=--max-old-space-size=4096
RUN yarn build:app:docker

# --- the store, ours ---------------------------------------------------------
# The usual self-hosted store is a Node service whose published image has not
# moved since February 2022. This one is a single static binary over SQLite with
# the same routes. See backend/main.go for what it keeps and why.
FROM golang:1.25-alpine AS store
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/excalidraw-store .

# --- the room server ---------------------------------------------------------
# Upstream's own relay. It forwards messages between connected browsers and
# stores nothing, which is exactly why the store above exists.
FROM excalidraw/excalidraw-room:latest AS room

# --- last outbound references ------------------------------------------------
# At build time, so the running container never reaches for the network, and so
# a build that cannot make the image self-contained fails instead of shipping.
FROM alpine:3.22 AS patch
RUN apk add --no-cache curl
COPY --from=web /src/excalidraw-app/build /html
COPY rootfs/usr/local/bin/patch-spa.sh /patch-spa.sh
RUN sh /patch-spa.sh /html

# --- runtime -----------------------------------------------------------------
FROM node:24-alpine

RUN apk add --no-cache nginx openssl tini \
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
