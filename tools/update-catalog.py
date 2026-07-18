#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)
EMIT_FIELDS = (
    "id",
    "name",
    "version",
    "author",
    "license",
    "icon",
    "description",
    "deprecated",
    "plugin_api",
    "tags",
)
ID_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def fail(path: Path, field: str, message: str) -> None:
    raise ValueError(f"{rel(path)}: {field}: {message}")


def require_string(manifest: dict[str, Any], path: Path, field: str) -> str:
    if field not in manifest:
        fail(path, field, "missing required field")
    value = manifest[field]
    if not isinstance(value, str) or not value:
        fail(path, field, "must be a non-empty string")
    return value


def require_positive_int(manifest: dict[str, Any], path: Path, field: str) -> int:
    if field not in manifest:
        fail(path, field, "missing required field")
    value = manifest[field]
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(path, field, "must be a positive integer")
    return value


def require_tags(manifest: dict[str, Any], path: Path) -> list[str]:
    if "tags" not in manifest:
        fail(path, "tags", "missing required field")
    tags = manifest["tags"]
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        fail(path, "tags", "must be an array of strings")
    return tags


def read_manifest(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        raw = tomllib.load(handle)

    plugin_id = require_string(raw, path, "id")
    if not ID_PATTERN.fullmatch(plugin_id):
        fail(path, "id", "must have author/plugin shape")

    plugin: dict[str, Any] = {
        "id": plugin_id,
        "name": require_string(raw, path, "name"),
        "version": require_string(raw, path, "version"),
        "author": require_string(raw, path, "author"),
        "plugin_api": require_positive_int(raw, path, "plugin_api"),
        "tags": require_tags(raw, path),
        "_directory": path.parent.name,
    }

    for field in OPTIONAL_STRING_FIELDS:
        if field in raw:
            value = raw[field]
            if not isinstance(value, str):
                fail(path, field, "must be a string")
            plugin[field] = value

    for field in OPTIONAL_BOOL_FIELDS:
        if field in raw:
            value = raw[field]
            if not isinstance(value, bool):
                fail(path, field, "must be a boolean")
            plugin[field] = value

    return plugin


def existing_id_order() -> dict[str, int]:
    if not CATALOG.exists():
        return {}

    content = CATALOG.read_text(encoding="utf-8")
    ids = re.findall(r'(?m)^id\s*=\s*"((?:\\.|[^"\\])*)"', content)
    return {plugin_id: index for index, plugin_id in enumerate(ids)}


def discover_plugins() -> list[dict[str, Any]]:
    preserved_order = existing_id_order()
    plugins = [read_manifest(path) for path in sorted(ROOT.glob("*/plugin.toml"))]
    plugins.sort(
        key=lambda plugin: (
            preserved_order.get(plugin["id"], len(preserved_order)),
            plugin["_directory"],
        )
    )
    return plugins


def toml_string(value: str) -> str:
    escaped = []
    replacements = {
        "\\": "\\\\",
        '"': '\\"',
        "\b": "\\b",
        "\t": "\\t",
        "\n": "\\n",
        "\f": "\\f",
        "\r": "\\r",
    }
    for char in value:
        if char in replacements:
            escaped.append(replacements[char])
        elif ord(char) < 0x20:
            escaped.append(f"\\u{ord(char):04x}")
        else:
            escaped.append(char)
    return '"' + "".join(escaped) + '"'


def toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_string(item) for item in value) + "]"
    if isinstance(value, str):
        return toml_string(value)
    raise TypeError(f"cannot render TOML value of type {type(value).__name__}")


def render_catalog(plugins: list[dict[str, Any]]) -> str:
    lines = [
        "# This file is auto-generated from */plugin.toml by tools/update-catalog.py.",
        "# Do not edit manually.",
        "",
    ]

    for index, plugin in enumerate(plugins):
        if index:
            lines.append("")

        lines.append("[[plugin]]")
        for field in EMIT_FIELDS:
            if field in plugin:
                lines.append(f"{field} = {toml_value(plugin[field])}")

    return "\n".join(lines) + "\n"


def main() -> int:
    plugins = discover_plugins()
    old_content = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
    new_content = render_catalog(plugins)
    CATALOG.write_text(new_content, encoding="utf-8")

    status = "changed" if old_content != new_content else "unchanged"
    count_label = "plugin" if len(plugins) == 1 else "plugins"
    print(f"catalog.toml: {len(plugins)} {count_label}, {status}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
