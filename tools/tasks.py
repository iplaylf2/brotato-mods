from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

from dotenv import load_dotenv

REPOSITORY = Path(__file__).resolve().parents[1]
load_dotenv(REPOSITORY / ".env")

CONTENT = REPOSITORY / "content"
MODS = CONTENT / "mods-unpacked"
IMPORTED_RESOURCES = CONTENT / ".import"
THIS_FILE = Path(__file__).relative_to(REPOSITORY)
PKG_RESOURCES_WARNING = "ignore:pkg_resources is deprecated as an API:UserWarning"
GODOT_VALIDATOR = REPOSITORY / "tools" / "validate_godot_scripts.gd"
AUTOPILOT_MODEL_CHECKS = REPOSITORY / "tools" / "check_autopilot_model_contracts.gd"
EXPECTED_GODOT_VERSION = (3, 7, "dev")
IMPORTED_RESOURCE_PATTERN = re.compile(r'res://(\.import/[^"\r\n]+)')


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


def validate_manifest(mod_directory: Path) -> None:
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
        raise SystemExit(f"{relative_manifest}: namespace must be a non-empty string")
    if not isinstance(name, str) or not name:
        raise SystemExit(f"{relative_manifest}: name must be a non-empty string")

    expected_directory = f"{namespace}-{name}"
    if mod_directory.name != expected_directory:
        relative_path = mod_directory.relative_to(REPOSITORY)
        raise SystemExit(
            f"{relative_path}: directory must be named {expected_directory!r}"
        )


def validate_manifests() -> None:
    mod_directories = sorted(path for path in MODS.iterdir() if path.is_dir())
    if not mod_directories:
        raise SystemExit("error: no mods found under content/mods-unpacked")
    for mod_directory in mod_directories:
        validate_manifest(mod_directory)


def resolve_configured_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = REPOSITORY / path
    return path.resolve()


def resolve_godot() -> str:
    configured_executable = os.environ.get("GODOT_EXECUTABLE")
    if not configured_executable:
        raise SystemExit(
            "error: GODOT_EXECUTABLE must point to a Godot 3.7.dev executable"
        )

    executable = resolve_configured_path(configured_executable)
    if not executable.is_file():
        raise SystemExit(f"error: GODOT_EXECUTABLE is not a file: {executable}")
    if os.name != "nt" and not os.access(executable, os.X_OK):
        raise SystemExit(f"error: GODOT_EXECUTABLE is not executable: {executable}")
    return str(executable)


def resolve_build_directory() -> Path:
    configured_directory = os.environ.get("BROTATO_MOD_BUILD_DIR")
    if not configured_directory:
        raise SystemExit(
            "error: BROTATO_MOD_BUILD_DIR must point to the ZIP output directory"
        )
    build_directory = resolve_configured_path(configured_directory)
    if build_directory == CONTENT or CONTENT in build_directory.parents:
        raise SystemExit(
            "error: BROTATO_MOD_BUILD_DIR must be outside the content directory"
        )
    if build_directory.exists() and not build_directory.is_dir():
        raise SystemExit(
            f"error: BROTATO_MOD_BUILD_DIR is not a directory: {build_directory}"
        )
    return build_directory


def validate_godot_version(executable: str) -> None:
    result = subprocess.run(
        (executable, "--version"),
        cwd=REPOSITORY,
        check=True,
        capture_output=True,
        text=True,
    )
    version_output = f"{result.stdout}\n{result.stderr}".strip()
    version_match = re.search(r"\b(\d+)\.(\d+)\.([A-Za-z]+)", version_output)
    if not version_match:
        raise SystemExit(
            f"error: could not read the Godot version from: {version_output!r}"
        )

    version = (
        int(version_match.group(1)),
        int(version_match.group(2)),
        version_match.group(3).lower(),
    )
    if version != EXPECTED_GODOT_VERSION:
        expected = ".".join(str(part) for part in EXPECTED_GODOT_VERSION)
        actual = version_match.group(0)
        raise SystemExit(
            f"error: GODOT_EXECUTABLE must use Godot {expected}; found {actual}"
        )


def validate_godot_models() -> None:
    configured_project = os.environ.get("BROTATO_PROJECT")
    if not configured_project:
        raise SystemExit(
            "error: BROTATO_PROJECT must point to a locally recovered Brotato project"
        )

    project = resolve_configured_path(configured_project)
    if not (project / "project.godot").is_file():
        raise SystemExit(
            f"error: BROTATO_PROJECT does not contain project.godot: {project}"
        )

    godot = resolve_godot()
    validate_godot_version(godot)

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
            godot,
            "--path",
            str(project.resolve()),
            "--script",
            str(GODOT_VALIDATOR),
            "--",
            str(archive),
            environment_overrides=user_data_environment,
        )
        run(
            godot,
            "--path",
            str(project.resolve()),
            "--script",
            str(AUTOPILOT_MODEL_CHECKS),
            "--",
            str(archive),
            environment_overrides=user_data_environment,
        )


def lint_portable() -> None:
    validate_manifests()
    run("ruff", "check", "tools")
    run("ruff", "format", "--check", "tools")
    run(
        "gdlint",
        str(MODS),
        str(GODOT_VALIDATOR),
        str(AUTOPILOT_MODEL_CHECKS),
        suppress_pkg_resources_warning=True,
    )
    run(
        "gdformat",
        "--check",
        str(MODS),
        str(GODOT_VALIDATOR),
        str(AUTOPILOT_MODEL_CHECKS),
        suppress_pkg_resources_warning=True,
    )


def lint() -> None:
    lint_portable()
    validate_godot_models()


def collect_imported_resources(mod_directory: Path) -> set[Path]:
    imported_resources: set[Path] = set()
    imported_resources_root = IMPORTED_RESOURCES.resolve()
    for import_metadata in sorted(mod_directory.rglob("*.import")):
        contents = import_metadata.read_text(encoding="utf-8")
        for relative_path in IMPORTED_RESOURCE_PATTERN.findall(contents):
            resource = (CONTENT / relative_path).resolve()
            if (
                resource == imported_resources_root
                or imported_resources_root not in resource.parents
            ):
                metadata_path = import_metadata.relative_to(REPOSITORY)
                raise SystemExit(
                    f"{metadata_path}: import artifact must be under content/.import: "
                    f"{relative_path}"
                )
            if not resource.is_file():
                metadata_path = import_metadata.relative_to(REPOSITORY)
                raise SystemExit(
                    f"{metadata_path}: referenced import artifact is missing: "
                    f"{relative_path}"
                )
            imported_resources.add(resource)
    return imported_resources


def build_archive(mod_id: str) -> None:
    if Path(mod_id).name != mod_id or mod_id in {".", ".."}:
        raise SystemExit(f"error: invalid mod ID: {mod_id!r}")
    mod_directory = MODS / mod_id
    if not mod_directory.is_dir():
        raise SystemExit(f"error: mod not found: {mod_id!r}")

    validate_manifest(mod_directory)
    build_directory = resolve_build_directory()
    build_directory.mkdir(parents=True, exist_ok=True)
    archive = build_directory / f"{mod_directory.name}.zip"
    files = {path for path in mod_directory.rglob("*") if path.is_file()}
    files.update(collect_imported_resources(mod_directory))
    with tempfile.TemporaryDirectory(
        prefix=f".{mod_directory.name}-", dir=build_directory
    ) as temporary_directory:
        temporary_archive = Path(temporary_directory) / archive.name
        with zipfile.ZipFile(
            temporary_archive,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as output:
            for source in sorted(files):
                output.write(source, source.relative_to(CONTENT))
        temporary_archive.replace(archive)
    print(f"built {archive}")


def format_sources() -> None:
    run("ruff", "format", "tools")
    run(
        "gdformat",
        str(MODS),
        str(GODOT_VALIDATOR),
        str(AUTOPILOT_MODEL_CHECKS),
        suppress_pkg_resources_warning=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        prog=f"uv run --locked {THIS_FILE}",
        description="Run Brotato mod repository tasks.",
    )
    subparsers = parser.add_subparsers(dest="task", required=True)

    build_parser = subparsers.add_parser(
        "build",
        help="build one mod ZIP",
        description=(
            "Build one mod ZIP in the directory configured by BROTATO_MOD_BUILD_DIR."
        ),
    )
    build_parser.add_argument(
        "mod_id",
        metavar="MOD_ID",
        help="directory name under content/mods-unpacked",
    )
    subparsers.add_parser("lint", help="run all checks")
    subparsers.add_parser("lint-portable", help="run checks without local game files")
    subparsers.add_parser("format", help="format managed source files")

    arguments = parser.parse_args()
    if arguments.task == "build":
        build_archive(arguments.mod_id)
    elif arguments.task == "lint":
        lint()
    elif arguments.task == "lint-portable":
        lint_portable()
    elif arguments.task == "format":
        format_sources()
    else:
        raise AssertionError(f"unhandled task: {arguments.task}")


if __name__ == "__main__":
    main()
