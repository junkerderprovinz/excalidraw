#!/bin/sh
# Point the upstream SPA back at its own origin. Runs once, at image build time.
#
# Everything here was measured against the upstream image rather than guessed,
# because two of the four facts are not what the documentation suggests:
#
#   1. The storage route is /api/v2/scenes, NOT the /api/v2/post/ the bundle is
#      built with. The backend prints its own routes on startup; the mismatch is
#      invisible until a share silently 404s.
#   2. The fonts are ALREADY in the image, under fonts/<Family>/..., except the
#      four Assistant faces. Those are fetched here, once, so the running
#      container never reaches for the network.
#   3. The analytics script sits in index.html, not in the bundle.
#   4. There is no integrity hash on the bundle, so rewriting it is safe.
#
# Fails loudly: a silent no-op here would ship an image that still calls home,
# and nothing downstream would notice.
set -eu

HTML="${1:?usage: patch-spa.sh <html-root>}"
CDN="https://excalidraw.nyc3.cdn.digitaloceanspaces.com/oss/"
API="https://json.excalidraw.com/api/v2/"
WS="https://oss-collab.excalidraw.com"

bundle=$(find "$HTML/assets" -name 'index-*.js' | head -1)
[ -n "$bundle" ] || { echo "patch-spa: no bundle found under $HTML/assets" >&2; exit 1; }

# --- 1. the shared-link store ------------------------------------------------
# The longer path first: /api/v2/post is a prefix-mate of /api/v2/, and the other
# order would rewrite the shorter one into the middle of the longer one.
grep -q "$API" "$bundle" || { echo "patch-spa: store URL not found, upstream changed" >&2; exit 1; }
sed -i "s#${API}post#/api/v2/scenes#g" "$bundle"
sed -i "s#${API}#/api/v2/scenes/#g" "$bundle"

# --- 2. the collaboration socket --------------------------------------------
# An empty string makes socket.io connect to the page's own origin, which is
# exactly what we want and needs no address to be configured anywhere.
grep -q "$WS" "$bundle" || { echo "patch-spa: socket URL not found, upstream changed" >&2; exit 1; }
sed -i "s#${WS}##g" "$bundle"

# --- 3. the fonts ------------------------------------------------------------
# Collect every CDN reference from the HTML and the stylesheet, fetch the ones
# the image does not already carry, then make every reference relative.
targets="$HTML/index.html $(find "$HTML/assets" -name '*.css')"
# shellcheck disable=SC2086
urls=$(grep -oh "${CDN}[^)\"' ]*" $targets | sort -u || true)
fetched=0
for u in $urls; do
  rel=${u#"$CDN"}
  [ -n "$rel" ] || continue
  case "$rel" in */) continue ;; esac
  if [ ! -f "$HTML/$rel" ]; then
    mkdir -p "$HTML/$(dirname "$rel")"
    curl -fsSL --retry 3 -o "$HTML/$rel" "$u"
    fetched=$((fetched + 1))
  fi
done
# shellcheck disable=SC2086
sed -i "s#${CDN}##g" $targets

# --- 4. the analytics script -------------------------------------------------
sed -i '/simpleanalytics/d' "$HTML/index.html"

# --- proof, not hope ---------------------------------------------------------
left=$(grep -rl "digitaloceanspaces\|simpleanalytics\|json.excalidraw.com\|oss-collab" "$HTML" 2>/dev/null || true)
if [ -n "$left" ]; then
  echo "patch-spa: outbound references still present in:" >&2
  echo "$left" >&2
  exit 1
fi

echo "patch-spa: rewritten, ${fetched} font file(s) fetched, no outbound references left"
