#!/bin/sh
# Take the last outbound references out of the built SPA, and prove none are
# left. Runs once, at image build time, so the running container never reaches
# for the network and every start is identical.
#
# The addresses the app talks to are build variables and are already correct by
# the time this runs. Two things are not variables, and this is what they are:
#
#   fonts      referenced from index.html and the stylesheet against a CDN,
#              even though most of the files are in the build. The missing ones
#              are fetched here, once, and every reference is made relative.
#   analytics  a script tag in index.html.
#
# Fails loudly on anything it cannot account for. A silent pass here would ship
# an image that still calls home while claiming it does not, and nothing
# downstream would notice.
set -eu

HTML="${1:?usage: patch-spa.sh <html-root>}"
CDN="https://excalidraw.nyc3.cdn.digitaloceanspaces.com/oss/"

[ -f "$HTML/index.html" ] || { echo "patch-spa: no index.html under $HTML" >&2; exit 1; }

# --- fonts -------------------------------------------------------------------
targets="$HTML/index.html $(find "$HTML/assets" -name '*.css' 2>/dev/null || true)"
# shellcheck disable=SC2086
urls=$(grep -oh "${CDN}[^)\"' ]*" $targets 2>/dev/null | sort -u || true)
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
[ -n "$urls" ] && sed -i "s#${CDN}##g" $targets

# --- analytics ---------------------------------------------------------------
sed -i '/simpleanalytics/d' "$HTML/index.html"

# --- proof, not hope ---------------------------------------------------------
# The gate for the whole promise of this image. If any of these strings survives
# anywhere in the build, the image is not what its description says it is, and
# the build stops here rather than shipping.
left=$(grep -rl \
  -e "digitaloceanspaces" \
  -e "simpleanalytics" \
  -e "json.excalidraw.com" \
  -e "oss-collab.excalidraw.com" \
  -e "firestore.googleapis.com" \
  -e "firebaseio.com" \
  "$HTML" 2>/dev/null || true)
if [ -n "$left" ]; then
  echo "patch-spa: outbound references still present in:" >&2
  echo "$left" >&2
  exit 1
fi

echo "patch-spa: ${fetched} font file(s) fetched, no outbound references left"
