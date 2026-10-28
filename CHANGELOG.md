# Changelog

All notable changes to this image are documented here. The full text of each
release is in `.github/release-notes/`.

## Unreleased

### 🔒 Security

- The room server no longer ships the dependency tree of its upstream image,
  which had not been rebuilt since 2023 and carried two critical and over
  thirty high advisories (minimist, proxy-addr, express, socket.io, ws and
  more). Its four runtime packages are installed fresh at fixed versions:
  express 4.22.3, socket.io 4.8.4, debug 4.4.3 and dotenv 10.0.0.
- npm, corepack and yarn are removed from the final image. Nothing uses them
  at runtime, and the bundled npm brought advisories of its own.

### ⚡ Improved

- Tidied the code comments and log messages.

## 1.0.0 — 2026-09-05

First release. Excalidraw, self-hosted, with nothing pointing outward: shared
links, the live session scene, pasted images, the collaboration socket and the
fonts all come from this container, and the analytics script is gone. The shape
library and text-to-diagram remain available as switches, off by default.

Built from a pinned upstream commit with one file replaced, the one that talks
to Firestore, and served over HTTPS because live collaboration needs a secure
context. A gate in the build refuses to produce an image that still calls home.

See [.github/release-notes/v1.0.0.md](.github/release-notes/v1.0.0.md).
