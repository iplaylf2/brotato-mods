from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from dotenv import load_dotenv

REPOSITORY = Path(__file__).resolve().parents[1]
load_dotenv(REPOSITORY / ".env")

MODS = REPOSITORY / "content" / "mods-unpacked"
THIS_FILE = Path(__file__).relative_to(REPOSITORY)
PKG_RESOURCES_WARNING = "ignore:pkg_resources is deprecated as an API:UserWarning"
GODOT_VALIDATOR = REPOSITORY / "tools" / "validate_godot_scripts.gd"


def run(
    *command: str,
    suppress_pkg_resources_warning: bool = False,
    environment_overrides: dict[str, str] | None = None,
) -> None:
    environment = os.environ.copy()
    if suppress_pkg_resources_warning:
        existing_warnings = environment.get("PYTHONWARNINGS")
        environment["PYTHONWARNINGS"] = ",".join(
            filter(None, (PKG_RESOURCES_WARNING, existing_warnings))
        )
    if environment_overrides:
        environment.update(environment_overrides)
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


def resolve_godot() -> str:
    for command in ("godotsteam", "godot3", "godot"):
        executable = shutil.which(command)
        if executable:
            return executable
    raise SystemExit("error: Godot 3.6 was not found on PATH")


def validate_godot_scripts() -> None:
    configured_project = os.environ.get("BROTATO_PROJECT")
    if not configured_project:
        raise SystemExit(
            "error: BROTATO_PROJECT must point to a locally recovered Brotato project"
        )

    project = Path(configured_project).expanduser()
    if not (project / "project.godot").is_file():
        raise SystemExit(
            f"error: BROTATO_PROJECT does not contain project.godot: {project}"
        )

    with tempfile.TemporaryDirectory(prefix="brotato-mod-lint-") as temp_directory:
        temporary_root = Path(temp_directory)
        archive = temporary_root / "mods.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for source in sorted(MODS.rglob("*")):
                if source.is_file():
                    output.write(source, source.relative_to(REPOSITORY / "content"))

        user_data_environment = {
            "APPDATA" if os.name == "nt" else "XDG_DATA_HOME": str(
                temporary_root / "user-data"
            )
        }
        run(
            resolve_godot(),
            "--path",
            str(project.resolve()),
            "--script",
            str(GODOT_VALIDATOR),
            "--",
            str(archive),
            environment_overrides=user_data_environment,
        )


def lint_portable() -> None:
    validate_manifests()
    run("ruff", "check", "tools")
    run("ruff", "format", "--check", "tools")
    run("gdlint", str(MODS), str(GODOT_VALIDATOR), suppress_pkg_resources_warning=True)
    run(
        "gdformat",
        "--check",
        str(MODS),
        str(GODOT_VALIDATOR),
        suppress_pkg_resources_warning=True,
    )


def lint() -> None:
    lint_portable()
    validate_godot_scripts()


def format_sources() -> None:
    run("ruff", "format", "tools")
    run(
        "gdformat", str(MODS), str(GODOT_VALIDATOR), suppress_pkg_resources_warning=True
    )


def main() -> None:
    tasks = {"lint": lint, "lint-portable": lint_portable, "format": format_sources}
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
