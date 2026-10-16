"""The download buttons the README shows, read by gen_download_buttons.py.

Each entry names a button the generator knows and where it leads. The rows,
their order, the colours and the words are the generator's, the same in every
repository.
"""

REPO = "excalidraw"

BUTTONS = {
    "unraid": "https://ca.unraid.net/apps/excalidraw-12jk2zv0fttlyf",
    "mos": "https://mos-official.net/apps.html?search=Excalidraw",
    "compose": "https://raw.githubusercontent.com/junkerderprovinz/excalidraw/main/compose.yaml",
    # A release's "Source code (zip)" is the whole repository at that tag, and
    # GitHub gives the newest one no fixed address, so this leads to the release
    # that lists it.
    "source": "https://github.com/junkerderprovinz/excalidraw/releases/latest",
}
