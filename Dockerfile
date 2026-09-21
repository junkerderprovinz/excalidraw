# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# excalidraw: a whiteboard that keeps to itself
#
# The published Excalidraw image is nginx over a built SPA, and that SPA talks
# to Excalidraw's own cloud: the shared-link store, the collaboration socket,
# the session scene in Google Firestore, a font CDN and an analytics script.
# Vite bakes those addresses into the bundle at build time, so none of them can
# be changed at runtime.
#
# This image builds the SPA itself and points every one of them back at the
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
# The API addresses are relative paths rather than an absolute URL built from a
# PUBLIC_URL variable. The browser resolves them against whatever address the
# page was opened on, so one image works on a LAN address, behind a reverse
# proxy, under a subdomain and over either protocol with nothing to configure.
# nginx routes those paths to the two services inside the container.
#
# HTTPS is not optional: live collaboration calls crypto.subtle, which a browser
# only exposes in a secure context. Over plain HTTP on a LAN address, starting a
# session dies with "Cannot read properties of undefined (reading 'generateKey')".
# So the image serves HTTPS with a certificate it generates on first start, and
# keeps the plain HTTP port for the single-user case where no session is started.

# The upstream commit this image is built from. Pinned, never "main": a
# whiteboard that rebuilds into something different every night cannot be
# supported, and the frontend patch has to be re-checked whenever it moves.
ARG EXCALIDRAW_SHA=214cd6e6e8ac3ad6b68486aa7aa7241abdf9445f

# The SPA, built once on the build platform: the output is JavaScript and the
# same for every target, while compiling Excalidraw under QEMU for arm64 takes the
# build from minutes into the better part of an hour.
FROM --platform=$BUILDPLATFORM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS web
ARG EXCALIDRAW_SHA
RUN apk add --no-cache git python3 make g++
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/excalidraw/excalidraw.git \
 && git fetch -q --depth 1 origin "${EXCALIDRAW_SHA}" \
 && git checkout -q FETCH_HEAD
# The one file that talked to Firestore: same six exports, same encryption,
# different destination. Its header says what stays untouched and why.
COPY frontend/firebase.ts excalidraw-app/data/firebase.ts
# The "Export to Excalidraw+" card uploads to the commercial hosted product,
# which is the one thing this image exists to avoid. Replaced, not deleted:
# App.tsx imports both of its exports.
COPY frontend/ExportToExcalidrawPlus.tsx excalidraw-app/components/ExportToExcalidrawPlus.tsx
RUN yarn install --frozen-lockfile --network-timeout 600000
ENV VITE_APP_BACKEND_V2_GET_URL=/api/v2/scenes/ \
    VITE_APP_BACKEND_V2_POST_URL=/api/v2/scenes \
    # "/" and not an empty string: socket.io resolves a leading slash against
    # the page's own origin, while an empty value reaches new URL("") and throws
    # "Invalid base URL" into the console on every load.
    VITE_APP_WS_SERVER_URL=/ \
    VITE_APP_ENABLE_TRACKING=false \
    VITE_APP_FIREBASE_CONFIG={} \
    NODE_OPTIONS=--max-old-space-size=4096
RUN yarn build:app:docker

# The store. The usual self-hosted one is a Node service whose published image
# has not moved since February 2022; this is a single static binary over SQLite
# with the same routes (see backend/main.go). Cross-compiled on the build
# platform, since Go does that in one step.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS store
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}     go build -trimpath -ldflags="-s -w" -o /out/excalidraw-store .

# The room server, upstream's own relay. It forwards messages between connected
# browsers and stores nothing. Pinned by digest because the image has no version
# tags, only :latest, and collaboration would otherwise change under a rebuild.
FROM excalidraw/excalidraw-room@sha256:2fe999f9be4379e3ee282fc45d75d84a691a6383dde33544514cc395287c7a70 AS room

# Removes the last outbound references at build time, so the running container
# never reaches for the network and a build that cannot make the image
# self-contained fails instead of shipping.
FROM --platform=$BUILDPLATFORM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS patch
RUN apk add --no-cache python3
COPY --from=web /src/excalidraw-app/build /html
COPY rootfs/usr/local/bin/patch-spa.py /patch-spa.py
RUN python3 /patch-spa.py /html

FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1

RUN apk add --no-cache nginx openssl tini \
 && rm -f /etc/nginx/http.d/default.conf

COPY --from=patch /html /usr/share/nginx/html
COPY --from=store /out/excalidraw-store /usr/local/bin/excalidraw-store
COPY --from=room /excalidraw-room /opt/room
COPY rootfs/ /
# The execute bit is set in git, but a checkout on a filesystem that does not
# carry it (Windows, a zip download) would give an image that dies at startup
# with "exec ... permission denied".
RUN chmod +x /usr/local/bin/start.sh

ENV STORE_ADDR=127.0.0.1:8081 \
    STORE_DB=/config/store.sqlite \
    ROOM_PORT=8082 \
    TZ=Etc/UTC

EXPOSE 80 443
VOLUME ["/config"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  # The shell is named rather than implied: the probe needs one for the "||",
  # and the exec form says so instead of leaving it to the image default.
  CMD ["sh", "-c", "wget -q -O /dev/null http://127.0.0.1/ || exit 1"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start.sh"]
