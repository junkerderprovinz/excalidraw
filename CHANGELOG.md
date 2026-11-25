# Changelog

All notable changes to this image are documented here. The full text of each
release is in `.github/release-notes/`.

## 1.0.3 - 2026-11-25

Excalidraw starts on Proxmox VE, the image follows a newer Excalidraw with
SQLite 1.63.0 and dotenv 18.0.10, and the published image gets the base
system's updates every week.

See [.github/release-notes/v1.0.3.md](.github/release-notes/v1.0.3.md).

## 1.0.2 - 2026-11-05

The room server moves to Express 5 and dotenv 18, the Node.js base image and
SQLite are updated, and `latest` now only moves with a release.

See [.github/release-notes/v1.0.2.md](.github/release-notes/v1.0.2.md).

## 1.0.1 - 2026-10-29

The room server ships only the four packages it runs, and the image no longer
carries a package manager. Also new: a compose file for other Docker hosts and
store buttons for MOS, ZimaOS and Umbrel in the README. The Node.js base image
and SQLite are updated.

See [.github/release-notes/v1.0.1.md](.github/release-notes/v1.0.1.md).

## 1.0.0 — 2026-09-05

First release. Excalidraw, self-hosted, with nothing pointing outward: shared
links, the live session scene, pasted images, the collaboration socket and the
fonts all come from this container, and the analytics script is gone. The shape
library and text-to-diagram remain available as switches, off by default.

Built from a pinned upstream commit with one file replaced, the one that talks
to Firestore, and served over HTTPS because live collaboration needs a secure
context. A gate in the build refuses to produce an image that still calls home.

See [.github/release-notes/v1.0.0.md](.github/release-notes/v1.0.0.md).
