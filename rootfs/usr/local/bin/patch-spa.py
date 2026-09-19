#!/usr/bin/env python3
"""Take the last outbound references out of the built SPA, and prove none are left.

Runs once, at image build time, so the running container never reaches for the
network and every start is identical.

The addresses the app talks to are build variables and are already correct by
the time this runs. Two things are not variables:

  fonts      referenced against a CDN from index.html, the stylesheet and
             `window.EXCALIDRAW_ASSET_PATH`, even though most of the files are
             in the build. The missing ones are fetched here, once.
  analytics  a script the page builds and appends at runtime.

Python rather than sed, because line-based edits are the wrong tool for minified
HTML: they leave fragments behind that fail only in the browser console.
"""

import os
import re
import sys
import urllib.request

CDN = "https://excalidraw.nyc3.cdn.digitaloceanspaces.com/oss/"

# Anything still pointing at somebody else's server when this is done. The shape
# library and the AI endpoint are real features rather than telemetry, so they
# stay in the build and are switched at start time instead (see start.sh), off
# by default.
FORBIDDEN = (
    "digitaloceanspaces",
    "simpleanalytics",
    "json.excalidraw.com",
    "oss-collab.excalidraw.com",
    "firestore.googleapis.com",
    "firebaseio.com",
)

# The two switchable ones have to stay in the build: start.sh turns them off by
# rewriting exactly these strings, and after a rename upstream the switch would
# point at nothing while the container still called home.
SWITCHABLE = (
    "libraries.excalidraw.com",
    "oss-ai.excalidraw.com",
)


def fail(msg):
    print(f"patch-spa: {msg}", file=sys.stderr)
    raise SystemExit(1)


def text_files(root):
    for base, _, names in os.walk(root):
        for n in names:
            if n.endswith((".html", ".css", ".js", ".webmanifest", ".json")):
                yield os.path.join(base, n)


def main():
    if len(sys.argv) != 2:
        fail("usage: patch-spa.py <html-root>")
    root = sys.argv[1]
    index = os.path.join(root, "index.html")
    if not os.path.isfile(index):
        fail(f"no index.html under {root}")

    # Fonts: fetch whatever the build does not already carry, then make every
    # reference site-relative. "/" and not "": the asset path is a list the app
    # feeds to new URL(), and an empty entry there throws on every load.
    fetched = 0
    for path in text_files(root):
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            body = fh.read()
        if CDN not in body:
            continue
        for url in sorted(set(re.findall(re.escape(CDN) + r"[^)\"'\s]*", body))):
            rel = url[len(CDN):]
            if not rel or rel.endswith("/"):
                continue
            target = os.path.join(root, rel)
            if not os.path.isfile(target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                urllib.request.urlretrieve(url, target)
                fetched += 1
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(body.replace(CDN, "/"))

    # Analytics: remove the whole script element, not the line that names the
    # host. The script is built at runtime, and a leftover half of it is a syntax
    # error on every load.
    with open(index, encoding="utf-8", errors="surrogateescape") as fh:
        html = fh.read()
    before = html
    html = re.sub(
        r"<script>(?:(?!</script>).)*simpleanalytics(?:(?!</script>).)*</script>",
        "",
        html,
        flags=re.S,
    )
    if html == before and "simpleanalytics" in before:
        fail("the analytics script is there but the pattern did not match it")
    with open(index, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(html)

    # If any outbound reference survives, the build stops instead of shipping an
    # image whose description is untrue.
    offenders = []
    for path in text_files(root):
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            body = fh.read()
        hits = [h for h in FORBIDDEN if h in body]
        if hits:
            offenders.append(f"{os.path.relpath(path, root)}: {', '.join(hits)}")
    if offenders:
        print("patch-spa: outbound references still present:", file=sys.stderr)
        for line in offenders:
            print("  " + line, file=sys.stderr)
        raise SystemExit(1)

    # And the other direction: the switchable addresses have to be there.
    everything = ""
    for path in text_files(root):
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            everything += fh.read()
    missing = [s for s in SWITCHABLE if s not in everything]
    if missing:
        fail(
            "these are gone from the build, so the runtime switches would do "
            "nothing: " + ", ".join(missing)
        )

    print(f"patch-spa: {fetched} font file(s) fetched, no outbound references left")


if __name__ == "__main__":
    main()
