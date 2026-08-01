from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
MODS = REPOSITORY / "content" / "mods-unpacked"
THIS_FILE = Path(__file__).relative_to(REPOSITORY)
PKG_RESOURCES_WARNING = "ignore:pkg_resources is deprecated as an API:UserWarning"


def run(*command: str, suppress_pkg_resources_warning: bool = False) -> None:
    environment = os.environ.copy()
    if suppress_pkg_resources_warning:
        existing_warnings = environment.get("PYTHONWARNINGS")
        environment["PYTHONWARNINGS"] = ",".join(
            filter(None, (PKG_RESOURCES_WARNING, existing_warnings))
        )
    subprocess.run(command, cwd=REPOSITORY, env=environment, check=True)


def validate_manifests() -> None:
    mod_directories = sorted(path for path in MODS.iterdir() if path.is_dir())
    if not mod_directories:
        raise SystemExit("error: no mods found under content/mods-unpacked")

    for mod_directory in mod_directories:
        manifest = mod_directory / "manifest.json"
        entrypoint = mod_directory / "mod_main.gd"
        relative_manifest = manifest.relative_to(REPOSITORY)
        if not manifest.is_file():
            raise SystemExit(f"{relative_manifest}: file is required")
        if not entrypoint.is_file():
            relative_path = entrypoint.relative_to(REPOSITORY)
            raise SystemExit(f"{relative_path}: file is required")
        try:
            with manifest.open(encoding="utf-8") as file:
                manifest_data = json.load(file)
        except json.JSONDecodeError as error:
            raise SystemExit(f"{relative_manifest}: invalid JSON: {error}") from error

        if not isinstance(manifest_data, dict):
            raise SystemExit(f"{relative_manifest}: manifest must be a JSON object")
        namespace = manifest_data.get("namespace")
        name = manifest_data.get("name")
        if not isinstance(namespace, str) or not namespace:
            raise SystemExit(
                f"{relative_manifest}: namespace must be a non-empty string"
            )
        if not isinstance(name, str) or not name:
            raise SystemExit(f"{relative_manifest}: name must be a non-empty string")

        expected_directory = f"{namespace}-{name}"
        if mod_directory.name != expected_directory:
            relative_path = mod_directory.relative_to(REPOSITORY)
            raise SystemExit(
                f"{relative_path}: directory must be named {expected_directory!r}"
            )


def lint() -> None:
    validate_manifests()
    run("ruff", "check", "tools")
    run("ruff", "format", "--check", "tools")
    run("gdlint", str(MODS), suppress_pkg_resources_warning=True)
    run("gdformat", "--check", str(MODS), suppress_pkg_resources_warning=True)


def format_sources() -> None:
    run("ruff", "format", "tools")
    run("gdformat", str(MODS), suppress_pkg_resources_warning=True)


def main() -> None:
    tasks = {"lint": lint, "format": format_sources}
    try:
        task = tasks[sys.argv[1]]
    except (IndexError, KeyError):
        choices = " | ".join(tasks)
        raise SystemExit(f"usage: uv run --locked {THIS_FILE} <{choices}>") from None
    if len(sys.argv) != 2:
        raise SystemExit(f"error: task {sys.argv[1]!r} does not accept arguments")
    task()


if __name__ == "__main__":
    main()
