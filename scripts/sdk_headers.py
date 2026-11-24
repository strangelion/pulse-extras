"""Published native SDK headers of the pinned Pulse revision.

Shared by `scripts/fetch_sdk.py` (download + verify) and
`scripts/generate_bindings.py` (translate-c input), so the two can never drift.
"""

HEADERS = [
    "abi",
    "context",
    "commands",
    "dispatch",
    "preview",
    "ui",
    "ui_model",
    "ui_data",
    "ui_mount",
    "ui_events",
    "dialogs",
    "directories",
    "fileops",
    "files",
    "resources",
    "settings_pages",
    "staging",
    "tasks",
]
