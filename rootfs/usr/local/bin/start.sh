#!/bin/sh
# Start the three processes this image is made of: the storage backend, the room
# server, and nginx in front of both.
#
# No process supervisor: tini is PID 1 and reaps, and if either node service dies
# the container should die with it rather than serve a whiteboard whose sharing
# silently stopped working. A half-working container is worse than a restarted
# one, because nobody notices the half.
set -eu

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

mkdir -p /config

# --- certificate -------------------------------------------------------------
# Live collaboration needs a secure context (crypto.subtle), so HTTPS is not a
# nicety here. A self-signed certificate is generated once and kept in /config,
# so it survives a container rebuild and a browser only has to be told once.
CERT=/config/cert.pem
KEY=/config/key.pem
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  log "no certificate in /config, generating a self-signed one (valid 10 years)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=excalidraw" \
    -addext "subjectAltName=DNS:excalidraw,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
  chmod 600 "$KEY"
fi

# --- store -------------------------------------------------------------------
# Ours: one static binary, SQLite in /config. Scenes, rooms and files.
log "store on ${STORE_ADDR}, database ${STORE_DB}"
excalidraw-store &
STORAGE_PID=$!

# --- room server -------------------------------------------------------------
export PORT="$ROOM_PORT"
log "room server on :${ROOM_PORT}"
node /opt/room/dist/index.js &
ROOM_PID=$!

# --- nginx -------------------------------------------------------------------
# Waits for both, so the first request cannot land on a socket nobody listens to.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if wget -q -O /dev/null "http://127.0.0.1:${ROOM_PORT}/" 2>/dev/null; then break; fi
  sleep 1
done

trap 'kill "$STORAGE_PID" "$ROOM_PID" 2>/dev/null' TERM INT

cat <<'BANNER'
   ___                 _ _     _
  | __|_ ____ __ _| (_)__| |_ _ __ ___ __ __ __
  | _|\ \ / _/ _` | | / _` | '_/ _` \ V  V /
  |___/_\_\__\__,_|_|_\__,_|_| \__,_|\_/\_/

BANNER
log "EXCALIDRAW IS READY  ->  https://<host>  (HTTP also served on :80)"

nginx -g 'daemon off;' &
NGINX_PID=$!

# Any of the three going down takes the container down, so a half-working
# whiteboard (drawing fine, sharing quietly broken) turns into a restart instead
# of a mystery. Written as a poll rather than `wait -n`, which busybox ash does
# not have: the first version used it and the container died on line 32 with
# "parameter not set", never reaching a single request.
while kill -0 "$STORAGE_PID" 2>/dev/null \
   && kill -0 "$ROOM_PID" 2>/dev/null \
   && kill -0 "$NGINX_PID" 2>/dev/null; do
  sleep 5
done
log "one of store, room or nginx exited, stopping the container"
kill "$STORAGE_PID" "$ROOM_PID" "$NGINX_PID" 2>/dev/null || true
exit 1
