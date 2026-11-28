"""Baseline SDK headers and deterministic ordering for reviewed additions."""

import re

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


def header_order(names) -> list[str]:
    """Retain baseline order for reproducibility; append reviewed additions."""
    names = set(names)
    if (not set(HEADERS) <= names or len(names) > 128
            or not all(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name)
                       for name in names)):
        raise ValueError("invalid or incomplete SDK header inventory")
    return HEADERS + sorted(names - set(HEADERS))
