#!/usr/bin/env python3
"""Launch DayPage's version-pinned DeepSeek Harness host safely.

The launcher deliberately does not ``source`` dotenv files. It parses only the
three DeepSeek provider variables needed by dsh, builds a small child environment,
and keeps Harness state outside the Git worktree.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence
from urllib.parse import urlparse


SELECTED_ENV_NAMES = (
    "DEEPSEEK_API_KEY",
    "DEEPSEEK_BASE_URL",
    "DEEPSEEK_MODEL",
)
REQUIRED_ENV_NAME = "DEEPSEEK_API_KEY"
DEFAULT_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-v4-pro"
ALLOWED_DEEPSEEK_HOSTS = frozenset({"api.deepseek.com"})
SAFE_CHILD_ENV_NAMES = frozenset(
    {
        "HOME",
        "LANG",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TERM",
        "TMPDIR",
        "USER",
        "COLORTERM",
        "NO_COLOR",
        "FORCE_COLOR",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    }
)
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?")
ENV_NAME_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
PLACEHOLDER_VALUES = frozenset(
    {
        "replace-me",
        "sk-replace-me",
        "your-api-key",
        "your_api_key",
    }
)


class DshConfigError(RuntimeError):
    """A local DSH configuration violates the DayPage adapter contract."""


@dataclass(frozen=True)
class DotenvSelection:
    path: Path
    values: Mapping[str, str]
    names: frozenset[str]


@dataclass(frozen=True)
class RuntimeConfig:
    root: Path
    env_file: Path
    dsh_home: Path
    dsh_version: str
    deepseek_base_url: str
    deepseek_model: str
    child_env: Mapping[str, str]


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def read_pinned_version(root: Path) -> str:
    path = root / ".dsh" / "version"
    try:
        version = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise DshConfigError(f"cannot read pinned DSH version: {error}") from error
    if VERSION_PATTERN.fullmatch(version) is None:
        raise DshConfigError(".dsh/version must contain one exact semantic version")
    return version


def _strip_dotenv_value(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value


def parse_dotenv(path: Path) -> DotenvSelection:
    """Parse names plus selected values without evaluating shell syntax."""

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise DshConfigError(f"cannot read dotenv file: {error}") from error
    except UnicodeDecodeError as error:
        raise DshConfigError("dotenv file must be UTF-8 text") from error

    names: set[str] = set()
    selected: dict[str, str] = {}
    for number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise DshConfigError(f"dotenv line {number} is not NAME=VALUE")
        raw_name, raw_value = line.split("=", 1)
        name = raw_name.strip()
        if ENV_NAME_PATTERN.fullmatch(name) is None:
            raise DshConfigError(f"dotenv line {number} has an invalid variable name")
        if name in names:
            raise DshConfigError(f"dotenv variable {name} is declared more than once")
        names.add(name)
        if name in SELECTED_ENV_NAMES:
            selected[name] = _strip_dotenv_value(raw_value)

    return DotenvSelection(path=path, values=selected, names=frozenset(names))


def _git_common_outer_env(root: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--git-common-dir"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return None
    common = Path(result.stdout.strip())
    if not common.is_absolute():
        common = (root / common).resolve()
    # <outer>/<canonical-checkout>/.git -> <outer>/.env
    return common.parent.parent / ".env"


def dotenv_candidates(root: Path, explicit: Path | None) -> list[Path]:
    if explicit is not None:
        return [explicit.expanduser().resolve()]

    candidates = [root / ".env"]
    common_outer = _git_common_outer_env(root)
    if common_outer is not None:
        candidates.append(common_outer)
    candidates.append(root.parent / ".env")

    unique: list[Path] = []
    seen: set[Path] = set()
    for candidate in candidates:
        resolved = candidate.expanduser().resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(resolved)
    return unique


def select_dotenv(root: Path, explicit: Path | None) -> DotenvSelection:
    candidates = dotenv_candidates(root, explicit)
    for candidate in candidates:
        if candidate.is_file():
            selection = parse_dotenv(candidate)
            if candidate == (root / ".env").resolve():
                extra_names = selection.names - frozenset(SELECTED_ENV_NAMES)
                if extra_names:
                    raise DshConfigError(
                        "repository .env contains variables outside the DSH allowlist; "
                        "use DAYPAGE_DSH_ENV_FILE instead"
                    )
            return selection
    if explicit is not None:
        raise DshConfigError("the explicitly selected dotenv file does not exist")
    raise DshConfigError(
        "no dotenv file found; set DAYPAGE_DSH_ENV_FILE to a protected file"
    )


def validate_secret_file_mode(path: Path) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise DshConfigError(
            "dotenv file must not grant group/other permissions; set mode 0600"
        )


def validate_deepseek_base_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_DEEPSEEK_HOSTS:
        raise DshConfigError(
            "DEEPSEEK_BASE_URL must use the official HTTPS DeepSeek endpoint"
        )
    try:
        port = parsed.port
    except ValueError as error:
        raise DshConfigError("DEEPSEEK_BASE_URL has an invalid port") from error
    if port not in {None, 443}:
        raise DshConfigError("DEEPSEEK_BASE_URL must use the default HTTPS port")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise DshConfigError("DEEPSEEK_BASE_URL must not contain credentials or query data")
    normalized_path = parsed.path.rstrip("/")
    if normalized_path not in {"", "/v1"}:
        raise DshConfigError("DEEPSEEK_BASE_URL path must be empty or /v1")
    return value.rstrip("/")


def validate_key(value: str) -> None:
    if not value or value.lower() in PLACEHOLDER_VALUES:
        raise DshConfigError("DEEPSEEK_API_KEY is missing or still a placeholder")


def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def resolve_dsh_home(root: Path, explicit: Path | None, environ: Mapping[str, str]) -> Path:
    raw = explicit or (
        Path(environ["DAYPAGE_DSH_HOME"])
        if environ.get("DAYPAGE_DSH_HOME")
        else Path.home() / ".dsh-daypage"
    )
    resolved = raw.expanduser().resolve()
    if _inside(resolved, root):
        raise DshConfigError("DSH state directory must live outside the repository")
    return resolved


def safe_child_environment(
    source: Mapping[str, str], selected: Mapping[str, str], dsh_home: Path
) -> dict[str, str]:
    child = {
        name: value
        for name, value in source.items()
        if name in SAFE_CHILD_ENV_NAMES or name.startswith("LC_")
    }
    child.update({name: value for name, value in selected.items() if value})
    child["DEEPSEEK_BASE_URL"] = selected.get("DEEPSEEK_BASE_URL") or DEFAULT_BASE_URL
    child["DEEPSEEK_MODEL"] = selected.get("DEEPSEEK_MODEL") or DEFAULT_MODEL
    child["DSH_HOME"] = str(dsh_home)
    child["DSH_PERMISSION_MODE"] = "workspace-write"
    # DSH exposes separate bootstrap and session-plugin telemetry controls.
    # Set both so a profile or bootstrap implementation change cannot reopen
    # telemetry implicitly.
    child["DSH_TELEMETRY_DISABLED"] = "1"
    child["DSH_TELEMETRY_MODE"] = "DISABLED"
    return child


def resolve_runtime_config(
    *,
    root: Path,
    explicit_env_file: Path | None,
    explicit_home: Path | None,
    environ: Mapping[str, str],
) -> RuntimeConfig:
    selection = select_dotenv(root, explicit_env_file)
    validate_secret_file_mode(selection.path)
    key = selection.values.get(REQUIRED_ENV_NAME, "")
    validate_key(key)
    base_url = validate_deepseek_base_url(
        selection.values.get("DEEPSEEK_BASE_URL") or DEFAULT_BASE_URL
    )
    model = selection.values.get("DEEPSEEK_MODEL") or DEFAULT_MODEL
    if not model or any(character.isspace() for character in model):
        raise DshConfigError("DEEPSEEK_MODEL must be one non-empty model id")
    dsh_home = resolve_dsh_home(root, explicit_home, environ)
    selected = dict(selection.values)
    selected["DEEPSEEK_BASE_URL"] = base_url
    selected["DEEPSEEK_MODEL"] = model
    return RuntimeConfig(
        root=root,
        env_file=selection.path,
        dsh_home=dsh_home,
        dsh_version=read_pinned_version(root),
        deepseek_base_url=base_url,
        deepseek_model=model,
        child_env=safe_child_environment(environ, selected, dsh_home),
    )


def _version_tuple(command: str) -> tuple[int, ...]:
    result = subprocess.run(
        [command, "--version"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise DshConfigError(f"cannot run {Path(command).name} --version")
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", result.stdout)
    if match is None:
        raise DshConfigError(f"cannot parse {Path(command).name} version")
    return tuple(int(value or 0) for value in match.groups())


def validate_toolchain() -> tuple[str, str]:
    node = shutil.which("node")
    pnpm = shutil.which("pnpm")
    if node is None:
        raise DshConfigError("Node.js is required")
    if pnpm is None:
        raise DshConfigError("pnpm is required")
    node_version = _version_tuple(node)
    if not (
        (node_version[0] == 22 and node_version[1] >= 19)
        or node_version[0] >= 24
    ):
        raise DshConfigError("DSH requires Node.js 22.19+ or 24+")
    pnpm_version = _version_tuple(pnpm)
    if pnpm_version[0] < 10:
        raise DshConfigError("DSH requires pnpm 10+")
    return node, pnpm


def ensure_dsh_home(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise DshConfigError("DSH state directory must use mode 0700")


def dsh_package(version: str) -> str:
    return f"@deepseek-ai/dsh@{version}"


def build_dsh_command(config: RuntimeConfig, action: str, extra: Iterable[str]) -> list[str]:
    pnpm = shutil.which("pnpm") or "pnpm"
    patch = config.root / ".dsh" / "daypage.patch.yml"
    command = [
        pnpm,
        "dlx",
        dsh_package(config.dsh_version),
        "web",
        "--patch",
        str(patch),
    ]
    if action == "dump-config":
        command.append("--dump-config")
    command.extend(extra)
    return command


def print_doctor(config: RuntimeConfig, *, probe_runtime: bool) -> int:
    node, pnpm = validate_toolchain()
    print(f"OK dsh.version: {config.dsh_version}")
    print(f"OK tool.node: {node}")
    print(f"OK tool.pnpm: {pnpm}")
    print("OK env.file: protected and allowlisted")
    print("OK env.DEEPSEEK_API_KEY: set (value redacted)")
    print(f"OK env.DEEPSEEK_BASE_URL: host={urlparse(config.deepseek_base_url).hostname}")
    print(f"OK env.DEEPSEEK_MODEL: {config.deepseek_model}")
    print("OK policy: workspace-write + ask; bootstrap and session telemetry disabled")
    print("OK state: outside repository")
    if probe_runtime:
        result = subprocess.run(
            [pnpm, "dlx", dsh_package(config.dsh_version), "--version"],
            cwd=config.root,
            env=dict(config.child_env),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if result.returncode != 0 or config.dsh_version not in result.stdout:
            raise DshConfigError("pinned DSH runtime probe failed")
        print("OK runtime: pinned package resolved")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--env-file",
        type=Path,
        help="dotenv file carrying only the selected DeepSeek values",
    )
    parser.add_argument("--home", type=Path, help="DSH state directory outside the repository")
    subparsers = parser.add_subparsers(dest="action", required=True)
    doctor = subparsers.add_parser("doctor", help="validate local DSH prerequisites")
    doctor.add_argument("--runtime", action="store_true", help="resolve and probe the pinned package")
    web = subparsers.add_parser("web", help="start the Agentic Web UI")
    web.add_argument("args", nargs=argparse.REMAINDER)
    dump = subparsers.add_parser("dump-config", help="print the effective DSH composition")
    dump.add_argument("args", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = repository_root()
    explicit_env = args.env_file
    if explicit_env is None and os.environ.get("DAYPAGE_DSH_ENV_FILE"):
        explicit_env = Path(os.environ["DAYPAGE_DSH_ENV_FILE"])
    try:
        config = resolve_runtime_config(
            root=root,
            explicit_env_file=explicit_env,
            explicit_home=args.home,
            environ=os.environ,
        )
        if args.action == "doctor":
            return print_doctor(config, probe_runtime=args.runtime)
        validate_toolchain()
        ensure_dsh_home(config.dsh_home)
        command = build_dsh_command(config, args.action, args.args)
        return subprocess.run(
            command,
            cwd=config.root,
            env=dict(config.child_env),
            check=False,
        ).returncode
    except DshConfigError as error:
        print(f"ERROR dsh: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
