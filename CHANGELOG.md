# Changelog

All notable changes to this image are documented here. The full text of each
release is in `.github/release-notes/`.

## 1.0.0 — 2026-09-05

First release. Excalidraw, self-hosted, with nothing pointing outward: shared
links, the live session scene, pasted images, the collaboration socket and the
fonts all come from this container, and the analytics script is gone. The shape
library and text-to-diagram remain available as switches, off by default.

Built from a pinned upstream commit with one file replaced, the one that talks
to Firestore, and served over HTTPS because live collaboration needs a secure
context. A gate in the build refuses to produce an image that still calls home.

See [.github/release-notes/v1.0.0.md](.github/release-notes/v1.0.0.md).
