#!/usr/bin/env python3
"""Validate DayPage's agent control-plane and local engineering prerequisites.

The contract scan intentionally covers current control-plane files, not legacy
task archives. Git-tracked run artifacts are checked repository-wide, with the
two pre-contract fixtures explicitly baselined until a separate cleanup removes
them from history.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 on the current macOS runner image.
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:  # pragma: no cover - reported as a contract error.
        tomllib = None  # type: ignore[assignment]


TEXT_SUFFIXES = {".md", ".toml", ".yaml", ".yml", ".json", ".sh"}
SKIP_PARTS = {"archive", "archives", "runs", "worktrees", ".git", "node_modules"}
DOC_SCOPE_PREFIXES = (
    "docs/README.md",
    "docs/architecture/",
    "docs/engineering/",
    "docs/agent-system/",
    "docs/adr/",
    "docs/decisions/",
)
CONTROL_SCOPE_PREFIXES = (".agents/", ".codex/", ".claude/", ".dsh/")
ROOT_CONTRACT_FILES = {"AGENTS.md", "CLAUDE.md", "README.md"}
PERSONAL_PATH = re.compile(
    r"(?:/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z]:\\Users\\[^\\\s]+)"
)
DANGEROUS_REMOTE_WRITE = re.compile(
    r"(?<![\w-])(?:"
    r"git\s+push(?:\s|$)|"
    r"gh\s+(?:pr|issue|release)\s+(?:create|edit|close|merge|delete)(?:\s|$)|"
    r"(?:npm|pnpm|yarn)\s+publish(?:\s|$)|"
    r"fastlane\s+(?:beta|release)(?:\s|$)|"
    r"supabase\s+db\s+(?:push|reset)(?:\s|$)"
    r")"
)
REMOTE_WRITE_MARKER = "agent-contract: explicit-user-action"
STALE_PROJECT_FACTS = (
    (
        re.compile(r"\b(?:single|one)\s+(?:Xcode\s+)?target\b", re.IGNORECASE),
        "DayPage has multiple Apple targets",
    ),
    (
        re.compile(r"\b(?:no|without)\s+(?:SPM|Swift Package Manager)\b", re.IGNORECASE),
        "DayPageKit is a Swift package",
    ),
    (
        re.compile(r"\b(?:no|without)\s+(?:tests?|test target)\b", re.IGNORECASE),
        "DayPage has Xcode, Swift package, script, and UI tests",
    ),
    (
        re.compile(r"\b(?:three|3)\s+tabs?\b", re.IGNORECASE),
        "the current iOS navigation is sidebar-based",
    ),
    (
        re.compile(
            r"\bGraph\b[^\n]{0,80}\b(?:disabled|placeholder|post[- ]?MVP)\b",
            re.IGNORECASE,
        ),
        "Graph is implemented",
    ),
    (
        re.compile(r"\bgenerated baseline enables\b", re.IGNORECASE),
        "repository Codex config does not auto-start external MCP servers",
    ),
)
REQUIRED_AGENT_FIELDS = {
    "name": str,
    "description": str,
    "developer_instructions": str,
}
LEGACY_TRACKED_RUN_BASELINE = {
    ".agents/skills/verify-daypage/runs/run-20260419-185229/env.json",
    ".agents/skills/verify-daypage/runs/run-20260419-185229/vault.state",
}


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    code: str
    message: str

    def render(self) -> str:
        location = self.path if self.line == 0 else f"{self.path}:{self.line}"
        return f"ERROR [{self.code}] {location}: {self.message}"


def git_tracked_files(root: Path) -> list[str] | None:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return None
    return [item.decode("utf-8", errors="surrogateescape") for item in result.stdout.split(b"\0") if item]


def filesystem_files(root: Path) -> list[str]:
    return [
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and not any(part in SKIP_PARTS for part in path.relative_to(root).parts)
    ]


def all_known_files(root: Path) -> list[str]:
    tracked = git_tracked_files(root)
    files = set(tracked if tracked is not None else filesystem_files(root))

    # Include non-ignored authoring work before it is staged without walking
    # ignored Claude worktrees, local run dumps, or dependency directories.
    if tracked is not None:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--others", "--exclude-standard"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            files.update(
                item.decode("utf-8", errors="surrogateescape")
                for item in result.stdout.split(b"\0")
                if item
            )
    for filename in ROOT_CONTRACT_FILES:
        if (root / filename).is_file():
            files.add(filename)
    return sorted(files)


def is_contract_text(path: str) -> bool:
    suffix = Path(path).suffix.lower()
    if suffix not in TEXT_SUFFIXES:
        return False
    if any(part in SKIP_PARTS for part in Path(path).parts):
        return False
    if path in ROOT_CONTRACT_FILES:
        return True
    if path.startswith(CONTROL_SCOPE_PREFIXES):
        return True
    return any(path == prefix or path.startswith(prefix) for prefix in DOC_SCOPE_PREFIXES)


def read_text(root: Path, path: str) -> str | None:
    try:
        return (root / path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def parse_simple_yaml_mapping(text: str) -> tuple[dict[str, object], list[tuple[int, str]]]:
    """Parse the small, mapping-only YAML subset used by agent manifest files."""

    root: dict[str, object] = {}
    stack: list[tuple[int, dict[str, object]]] = [(-2, root)]
    errors: list[tuple[int, str]] = []

    for number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if "\t" in raw_line[: len(raw_line) - len(raw_line.lstrip())]:
            errors.append((number, "tabs are not allowed for indentation"))
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent % 2:
            errors.append((number, "indentation must use two-space levels"))
            continue
        line = raw_line.strip()
        if line.startswith("-"):
            errors.append((number, "manifest must use mappings, not sequences"))
            continue
        if ":" not in line:
            errors.append((number, "expected `key: value` mapping entry"))
            continue
        key, raw_value = line.split(":", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
            errors.append((number, f"invalid mapping key {key!r}"))
            continue

        while stack and indent <= stack[-1][0]:
            stack.pop()
        if not stack or indent != stack[-1][0] + 2:
            errors.append((number, "invalid indentation level"))
            continue
        parent = stack[-1][1]
        if key in parent:
            errors.append((number, f"duplicate mapping key {key!r}"))
            continue

        value_text = raw_value.strip()
        if not value_text:
            child: dict[str, object] = {}
            parent[key] = child
            stack.append((indent, child))
            continue
        if value_text.startswith(("[", "{", "|", ">")):
            errors.append((number, "only scalar values and nested mappings are supported"))
            continue
        if (
            len(value_text) >= 2
            and value_text[0] in {"'", '"'}
            and value_text[-1] == value_text[0]
        ):
            value: object = value_text[1:-1]
        elif value_text.lower() in {"true", "false"}:
            value = value_text.lower() == "true"
        elif value_text.lower() in {"null", "~"}:
            value = None
        elif re.fullmatch(r"-?\d+", value_text):
            value = int(value_text)
        else:
            value = value_text
        parent[key] = value

    return root, errors


def parse_frontmatter(text: str) -> tuple[dict[str, str], str | None]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, "file must start with YAML frontmatter (`---`)"
    try:
        end = next(index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---")
    except StopIteration:
        return {}, "frontmatter is missing its closing `---`"

    values: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#") or line.startswith((" ", "\t")):
            continue
        if ":" not in line:
            return {}, f"invalid frontmatter entry: {line!r}"
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values, None


def resolve_repo_path(root: Path, value: object) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    raw_path = Path(value)
    if raw_path.is_absolute() or raw_path.anchor or ".." in raw_path.parts:
        return None
    resolved_root = root.resolve()
    resolved_target = (root / raw_path).resolve()
    try:
        resolved_target.relative_to(resolved_root)
    except ValueError:
        return None
    return resolved_target


def validate_repo_reference(
    root: Path,
    manifest_path: str,
    value: object,
    key_path: str,
    *,
    kind: str,
    within: str | None = None,
    suffix: str | None = None,
    filename: str | None = None,
) -> list[Finding]:
    """Validate one typed, root-contained repository manifest reference."""

    message_prefix = f"{key_path} must reference"
    if not isinstance(value, str) or not value:
        return [
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{message_prefix} a repository-relative {kind}",
            )
        ]

    raw_path = Path(value)
    resolved_target = resolve_repo_path(root, value)
    if resolved_target is None:
        return [
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{key_path} must be normalized, repository-relative, and resolve inside the repository: {value}",
            )
        ]

    findings: list[Finding] = []
    if within is not None:
        resolved_parent = (root / within).resolve()
        try:
            resolved_target.relative_to(resolved_parent)
        except ValueError:
            findings.append(
                Finding(
                    manifest_path,
                    0,
                    "manifest.reference",
                    f"{key_path} must stay under {within}: {value}",
                )
            )
    if kind == "file" and not resolved_target.is_file():
        findings.append(
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{key_path} must reference an existing file: {value}",
            )
        )
    elif kind == "directory" and not resolved_target.is_dir():
        findings.append(
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{key_path} must reference an existing directory: {value}",
            )
        )
    if suffix is not None and raw_path.suffix != suffix:
        findings.append(
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{key_path} must use the {suffix} suffix: {value}",
            )
        )
    if filename is not None and raw_path.name != filename:
        findings.append(
            Finding(
                manifest_path,
                0,
                "manifest.reference",
                f"{key_path} must reference {filename}: {value}",
            )
        )
    return findings


def manifest_reference_findings(
    root: Path,
    manifest_path: str,
    section_name: str,
    section: object,
) -> list[Finding]:
    findings: list[Finding] = []
    if not isinstance(section, dict) or not section:
        return [
            Finding(
                manifest_path,
                0,
                "manifest.section",
                f"required non-empty mapping missing: {section_name}",
            )
        ]

    section_specs = {
        "roles": {"kind": "file", "within": ".agents/roles", "suffix": ".md"},
        "workflows": {"kind": "file", "within": ".agents/workflows", "suffix": ".md"},
        "contracts": {"kind": "file", "within": ".agents/schemas", "suffix": ".json"},
        "templates": {"kind": "file", "within": ".agents/templates"},
    }
    if section_name in section_specs:
        for key, value in section.items():
            findings.extend(
                validate_repo_reference(
                    root,
                    manifest_path,
                    value,
                    f"{section_name}.{key}",
                    **section_specs[section_name],
                )
            )
        return findings

    if section_name == "skills":
        for skill_name, skill_config in section.items():
            if not isinstance(skill_config, dict) or not skill_config:
                findings.append(
                    Finding(
                        manifest_path,
                        0,
                        "manifest.reference",
                        f"skills.{skill_name} must be a non-empty mapping",
                    )
                )
                continue
            if "canonical" not in skill_config:
                findings.append(
                    Finding(
                        manifest_path,
                        0,
                        "manifest.reference",
                        f"skills.{skill_name}.canonical is required",
                    )
                )
            canonical = skill_config.get("canonical")
            findings.extend(
                validate_repo_reference(
                    root,
                    manifest_path,
                    canonical,
                    f"skills.{skill_name}.canonical",
                    kind="file",
                    within=".agents/skills",
                    filename="SKILL.md",
                )
            )
            for adapter_name, value in skill_config.items():
                if adapter_name == "canonical":
                    continue
                findings.extend(
                    validate_repo_reference(
                        root,
                        manifest_path,
                        value,
                        f"skills.{skill_name}.{adapter_name}",
                        kind="file",
                        filename="SKILL.md",
                    )
                )
        return findings

    if section_name == "dsh":
        for key, within, suffix in (
            ("version_file", ".dsh", None),
            ("launcher", "scripts/agent", ".py"),
            ("patch", ".dsh", ".yml"),
        ):
            findings.extend(
                validate_repo_reference(
                    root,
                    manifest_path,
                    section.get(key),
                    f"dsh.{key}",
                    kind="file",
                    within=within,
                    suffix=suffix,
                )
            )
        for key, expected in (("default_profile", "web"), ("default_preset", "standard")):
            if section.get(key) != expected:
                findings.append(
                    Finding(
                        manifest_path,
                        0,
                        "manifest.dsh",
                        f"dsh.{key} must be {expected!r}",
                    )
                )

        version_path = resolve_repo_path(root, section.get("version_file"))
        if version_path is not None and version_path.is_file():
            try:
                version = version_path.read_text(encoding="utf-8").strip()
            except (OSError, UnicodeDecodeError):
                version = ""
            if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
                findings.append(
                    Finding(
                        version_path.resolve().relative_to(root.resolve()).as_posix(),
                        1,
                        "command.unpinned",
                        "DSH version must be one exact semantic version",
                    )
                )
        return findings

    # The Codex section has two direct references, one required adapter mapping,
    # one optional helper mapping, and boolean policy metadata.
    findings.extend(
        validate_repo_reference(
            root,
            manifest_path,
            section.get("config"),
            "codex.config",
            kind="file",
            within=".codex",
            suffix=".toml",
        )
    )
    findings.extend(
        validate_repo_reference(
            root,
            manifest_path,
            section.get("agent_directory"),
            "codex.agent_directory",
            kind="directory",
            within=".codex",
        )
    )
    for mapping_name in ("role_adapters", "host_helpers"):
        adapters = section.get(mapping_name)
        if mapping_name == "host_helpers" and adapters is None:
            continue
        if not isinstance(adapters, dict) or not adapters:
            findings.append(
                Finding(
                    manifest_path,
                    0,
                    "manifest.reference",
                    f"codex.{mapping_name} must be a non-empty mapping",
                )
            )
            continue
        for adapter_name, value in adapters.items():
            findings.extend(
                validate_repo_reference(
                    root,
                    manifest_path,
                    value,
                    f"codex.{mapping_name}.{adapter_name}",
                    kind="file",
                    within=".codex/agents",
                    suffix=".toml",
                )
            )
    return findings


def validate_manifest(root: Path) -> list[Finding]:
    path = ".agents/manifest.yaml"
    text = read_text(root, path)
    if text is None:
        return [Finding(path, 0, "manifest.missing", "canonical agent manifest is required")]

    manifest, errors = parse_simple_yaml_mapping(text)
    if errors:
        return [
            Finding(path, line, "manifest.syntax", message)
            for line, message in errors
        ]
    if not manifest:
        return [Finding(path, 0, "manifest.syntax", "manifest must be a non-empty mapping")]

    findings: list[Finding] = []
    if manifest.get("schema_version") != 1:
        findings.append(
            Finding(path, 0, "manifest.version", "schema_version must be 1")
        )
    findings.extend(
        validate_repo_reference(
            root,
            path,
            manifest.get("canonical_root"),
            "canonical_root",
            kind="directory",
        )
    )
    for key in ("constitution", "documentation_index"):
        findings.extend(
            validate_repo_reference(
                root,
                path,
                manifest.get(key),
                key,
                kind="file",
                suffix=".md",
            )
        )
    for section_name in ("roles", "workflows", "contracts", "templates", "skills", "codex"):
        section = manifest.get(section_name)
        findings.extend(manifest_reference_findings(root, path, section_name, section))

    dsh = manifest.get("dsh")
    if dsh is not None:
        findings.extend(manifest_reference_findings(root, path, "dsh", dsh))

    for section_name, directory in (("roles", ".agents/roles"), ("workflows", ".agents/workflows")):
        section = manifest.get(section_name)
        if not isinstance(section, dict):
            continue
        for manifest_name, relative_path in section.items():
            target = resolve_repo_path(root, relative_path)
            if target is None or not target.is_file():
                continue
            try:
                text_value = target.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            metadata, error = parse_frontmatter(text_value)
            if error:
                findings.append(
                    Finding(relative_path, 1, f"{section_name[:-1]}.frontmatter", error)
                )
                continue
            actual_name = metadata.get("name")
            if actual_name != manifest_name:
                findings.append(
                    Finding(
                        relative_path,
                        1,
                        f"{section_name[:-1]}.name",
                        f"frontmatter name {actual_name!r} must match manifest key {manifest_name!r}",
                    )
                )

    skills = manifest.get("skills")
    if isinstance(skills, dict):
        for manifest_name, skill_config in skills.items():
            if not isinstance(skill_config, dict):
                continue
            canonical = skill_config.get("canonical")
            target = resolve_repo_path(root, canonical)
            if not isinstance(canonical, str) or target is None or not target.is_file():
                continue
            try:
                text_value = target.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            metadata, error = parse_frontmatter(text_value)
            if error is None and metadata.get("name") != manifest_name:
                findings.append(
                    Finding(
                        canonical,
                        1,
                        "skill.manifest-name",
                        f"frontmatter name {metadata.get('name')!r} must match manifest key {manifest_name!r}",
                    )
                )

    codex = manifest.get("codex")
    if tomllib is not None and isinstance(codex, dict):
        for mapping_name in ("role_adapters", "host_helpers"):
            adapters = codex.get(mapping_name)
            if not isinstance(adapters, dict):
                continue
            for manifest_name, relative_path in adapters.items():
                target = resolve_repo_path(root, relative_path)
                if target is None or not target.is_file():
                    continue
                try:
                    with target.open("rb") as handle:
                        adapter = tomllib.load(handle)
                except (OSError, tomllib.TOMLDecodeError):
                    continue  # The custom-agent validator reports the parse error.
                if adapter.get("name") != manifest_name:
                    findings.append(
                        Finding(
                            relative_path,
                            0,
                            "agent.manifest-name",
                            f"agent name {adapter.get('name')!r} must match manifest key {manifest_name!r}",
                        )
                    )
    return findings


def validate_skills(root: Path, files: Sequence[str]) -> list[Finding]:
    findings: list[Finding] = []
    skill_files = [
        path
        for path in files
        if path.startswith(".agents/skills/") and path.endswith("/SKILL.md")
    ]
    if not skill_files:
        findings.append(Finding(".agents/skills", 0, "skill.missing", "no canonical skills found"))
        return findings

    names: dict[str, str] = {}
    for path in skill_files:
        text = read_text(root, path)
        if text is None:
            findings.append(Finding(path, 0, "skill.read", "cannot read UTF-8 skill file"))
            continue
        metadata, error = parse_frontmatter(text)
        if error:
            findings.append(Finding(path, 1, "skill.frontmatter", error))
            continue
        name = metadata.get("name", "")
        description = metadata.get("description", "")
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
            findings.append(
                Finding(path, 1, "skill.name", "name must use lowercase kebab-case")
            )
        elif name in names:
            findings.append(
                Finding(path, 1, "skill.name", f"duplicate skill name; first declared in {names[name]}")
            )
        else:
            names[name] = path
        if not description:
            findings.append(Finding(path, 1, "skill.description", "description is required"))
        elif len(description) > 1024:
            findings.append(
                Finding(path, 1, "skill.description", "description must be at most 1024 characters")
            )
    return findings


VALID_JSON_SCHEMA_TYPES = {
    "array",
    "boolean",
    "integer",
    "null",
    "number",
    "object",
    "string",
}


def validate_json_schema_node(
    file_path: str,
    node: object,
    json_path: str = "$",
) -> list[Finding]:
    findings: list[Finding] = []
    if not isinstance(node, dict):
        return [
            Finding(file_path, 0, "schema.structure", f"{json_path} must be an object")
        ]

    schema_type = node.get("type")
    if schema_type is not None:
        types = schema_type if isinstance(schema_type, list) else [schema_type]
        if (
            not types
            or any(not isinstance(value, str) or value not in VALID_JSON_SCHEMA_TYPES for value in types)
            or len(set(types)) != len(types)
        ):
            findings.append(
                Finding(file_path, 0, "schema.type", f"{json_path}.type is invalid")
            )

    for keyword in ("minLength", "maxLength"):
        value = node.get(keyword)
        if value is not None and (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
        ):
            findings.append(
                Finding(
                    file_path,
                    0,
                    "schema.length",
                    f"{json_path}.{keyword} must be a non-negative integer",
                )
            )
    minimum_length = node.get("minLength")
    maximum_length = node.get("maxLength")
    if (
        isinstance(minimum_length, int)
        and not isinstance(minimum_length, bool)
        and isinstance(maximum_length, int)
        and not isinstance(maximum_length, bool)
        and minimum_length > maximum_length
    ):
        findings.append(
            Finding(
                file_path,
                0,
                "schema.length",
                f"{json_path}.minLength must not exceed maxLength",
            )
        )

    schema_format = node.get("format")
    if schema_format is not None and not isinstance(schema_format, str):
        findings.append(
            Finding(
                file_path,
                0,
                "schema.format",
                f"{json_path}.format must be a string",
            )
        )

    # `const` intentionally accepts any JSON value. Reaching this function
    # means json.loads has already proven that value is JSON-representable.

    properties = node.get("properties")
    if properties is not None:
        if not isinstance(properties, dict):
            findings.append(
                Finding(file_path, 0, "schema.properties", f"{json_path}.properties must be an object")
            )
        else:
            for property_name, child in properties.items():
                findings.extend(
                    validate_json_schema_node(
                        file_path,
                        child,
                        f"{json_path}.properties.{property_name}",
                    )
                )

    required = node.get("required")
    if required is not None:
        if (
            not isinstance(required, list)
            or any(not isinstance(value, str) for value in required)
            or len(set(required)) != len(required)
        ):
            findings.append(
                Finding(file_path, 0, "schema.required", f"{json_path}.required must contain unique strings")
            )
        elif isinstance(properties, dict):
            missing = sorted(set(required) - set(properties))
            if missing:
                findings.append(
                    Finding(
                        file_path,
                        0,
                        "schema.required",
                        f"{json_path}.required names missing properties: {', '.join(missing)}",
                    )
                )

    enum = node.get("enum")
    if enum is not None:
        if not isinstance(enum, list) or not enum:
            findings.append(
                Finding(file_path, 0, "schema.enum", f"{json_path}.enum must be a non-empty array")
            )
        elif len({json.dumps(item, sort_keys=True) for item in enum}) != len(enum):
            findings.append(
                Finding(file_path, 0, "schema.enum", f"{json_path}.enum contains duplicates")
            )

    items = node.get("items")
    if items is not None:
        findings.extend(validate_json_schema_node(file_path, items, f"{json_path}.items"))

    additional = node.get("additionalProperties")
    if additional is not None and not isinstance(additional, (bool, dict)):
        findings.append(
            Finding(
                file_path,
                0,
                "schema.additional-properties",
                f"{json_path}.additionalProperties must be boolean or a schema",
            )
        )
    elif isinstance(additional, dict):
        findings.extend(
            validate_json_schema_node(file_path, additional, f"{json_path}.additionalProperties")
        )

    for keyword in ("allOf", "anyOf", "oneOf"):
        branches = node.get(keyword)
        if branches is None:
            continue
        if not isinstance(branches, list) or not branches:
            findings.append(
                Finding(
                    file_path,
                    0,
                    "schema.composition",
                    f"{json_path}.{keyword} must be a non-empty array of schemas",
                )
            )
            continue
        for index, branch in enumerate(branches):
            findings.extend(
                validate_json_schema_node(
                    file_path,
                    branch,
                    f"{json_path}.{keyword}[{index}]",
                )
            )

    for keyword in ("not", "if", "then", "else"):
        branch = node.get(keyword)
        if branch is not None:
            findings.extend(
                validate_json_schema_node(file_path, branch, f"{json_path}.{keyword}")
            )

    for keyword in ("minItems", "maxItems"):
        value = node.get(keyword)
        if value is not None and (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
        ):
            findings.append(
                Finding(
                    file_path,
                    0,
                    "schema.cardinality",
                    f"{json_path}.{keyword} must be a non-negative integer",
                )
            )
    minimum = node.get("minItems")
    maximum = node.get("maxItems")
    if (
        isinstance(minimum, int)
        and not isinstance(minimum, bool)
        and isinstance(maximum, int)
        and not isinstance(maximum, bool)
        and minimum > maximum
    ):
        findings.append(
            Finding(
                file_path,
                0,
                "schema.cardinality",
                f"{json_path}.minItems must not exceed maxItems",
            )
        )
    return findings


def validate_json_schemas(root: Path, files: Sequence[str]) -> list[Finding]:
    schema_files = [
        path
        for path in files
        if path.startswith(".agents/schemas/") and path.endswith(".json")
    ]
    if not schema_files:
        return [
            Finding(".agents/schemas", 0, "schema.missing", "at least one JSON schema is required")
        ]

    findings: list[Finding] = []
    schema_ids: dict[str, str] = {}
    for path in schema_files:
        text = read_text(root, path)
        if text is None:
            findings.append(Finding(path, 0, "schema.read", "cannot read UTF-8 schema file"))
            continue
        try:
            schema = json.loads(text)
        except json.JSONDecodeError as error:
            findings.append(
                Finding(path, error.lineno, "schema.json", f"invalid JSON: {error.msg}")
            )
            continue
        if not isinstance(schema, dict):
            findings.append(Finding(path, 0, "schema.structure", "schema root must be an object"))
            continue
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            findings.append(
                Finding(path, 0, "schema.dialect", "schema must declare JSON Schema draft 2020-12")
            )
        schema_id = schema.get("$id")
        if not isinstance(schema_id, str) or not schema_id:
            findings.append(Finding(path, 0, "schema.id", "schema must declare a non-empty $id"))
        elif schema_id in schema_ids:
            findings.append(
                Finding(path, 0, "schema.id", f"duplicate $id; first declared in {schema_ids[schema_id]}")
            )
        else:
            schema_ids[schema_id] = path
        if schema.get("type") != "object":
            findings.append(Finding(path, 0, "schema.root-type", "schema root type must be object"))
        findings.extend(validate_json_schema_node(path, schema))
    return findings


def validate_personal_paths(root: Path, files: Sequence[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in filter(is_contract_text, files):
        text = read_text(root, path)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            match = PERSONAL_PATH.search(line)
            if match:
                findings.append(
                    Finding(
                        path,
                        number,
                        "path.personal",
                        f"personal absolute path is not portable: {match.group(0)!r}",
                    )
                )
    return findings


def validate_stale_project_facts(root: Path, files: Sequence[str]) -> list[Finding]:
    """Reject known obsolete claims in current contracts and host adapters.

    This is deliberately a small denylist of facts that previously drifted
    across AGENTS/CLAUDE/README-style guidance. Historical documents are out
    of scope; current architectural truth still requires human review.
    """

    findings: list[Finding] = []
    for path in filter(is_contract_text, files):
        text = read_text(root, path)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            for pattern, current_fact in STALE_PROJECT_FACTS:
                if pattern.search(line):
                    findings.append(
                        Finding(
                            path,
                            number,
                            "fact.stale",
                            f"known stale project claim; current fact: {current_fact}",
                        )
                    )
    return findings


def validate_tracked_runs(root: Path) -> list[Finding]:
    tracked = git_tracked_files(root)
    if tracked is None:
        tracked = filesystem_files(root)
    findings: list[Finding] = []
    for path in tracked:
        parts = Path(path).parts
        if (
            path not in LEGACY_TRACKED_RUN_BASELINE
            and "runs" in parts
            and any(part in {".agents", ".codex", ".claude", ".dsh"} for part in parts)
        ):
            findings.append(
                Finding(path, 0, "runs.tracked", "agent run output must be ignored, not tracked")
            )
    return findings


def validate_codex_agents(root: Path, files: Sequence[str]) -> list[Finding]:
    findings: list[Finding] = []
    names: dict[str, str] = {}
    agent_files = [
        path
        for path in files
        if path.startswith(".codex/agents/") and path.endswith(".toml")
    ]
    if tomllib is None:
        return [Finding("python", 0, "toml.unsupported", "Python 3.11+ with tomllib is required")]
    for path in agent_files:
        try:
            with (root / path).open("rb") as handle:
                config = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as error:
            findings.append(Finding(path, 0, "agent.toml", f"invalid TOML: {error}"))
            continue
        for field, expected_type in REQUIRED_AGENT_FIELDS.items():
            value = config.get(field)
            if not isinstance(value, expected_type) or not value.strip():
                findings.append(
                    Finding(path, 0, "agent.field", f"required non-empty string field missing: {field}")
                )
        name = config.get("name")
        if isinstance(name, str) and name.strip():
            if name in names:
                findings.append(
                    Finding(
                        path,
                        0,
                        "agent.name",
                        f"duplicate custom agent name; first declared in {names[name]}",
                    )
                )
            else:
                names[name] = path
        sandbox = config.get("sandbox_mode")
        if sandbox is not None and (
            not isinstance(sandbox, str)
            or sandbox not in {"read-only", "workspace-write"}
        ):
            findings.append(
                Finding(path, 0, "agent.sandbox", "sandbox_mode must be read-only or workspace-write")
            )
        effort = config.get("model_reasoning_effort")
        if effort is not None and (
            not isinstance(effort, str)
            or effort not in {"minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
        ):
            findings.append(
                Finding(
                    path,
                    0,
                    "agent.effort",
                    "model_reasoning_effort must be a supported Codex effort level",
                )
            )
    return findings


def npx_package_is_pinned(package: str) -> bool:
    if package.startswith("@"):
        separator = package.rfind("@")
        return separator > 0 and bool(re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", package[separator + 1 :]))
    if "@" not in package:
        return False
    _, version = package.rsplit("@", 1)
    return bool(re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", version))


def validate_pinned_commands(root: Path) -> list[Finding]:
    path = ".codex/config.toml"
    config_path = root / path
    if not config_path.is_file():
        return [Finding(path, 0, "config.missing", "Codex repository config is required")]
    if tomllib is None:
        return [Finding("python", 0, "toml.unsupported", "Python 3.11+ or tomli is required")]
    try:
        with config_path.open("rb") as handle:
            config = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        return [Finding(path, 0, "config.toml", f"invalid TOML: {error}")]
    except OSError as error:
        return [Finding(path, 0, "config.read", f"cannot read Codex config: {error}")]

    if not isinstance(config, dict):
        return [Finding(path, 0, "config.toml", "Codex config root must be a table")]

    findings: list[Finding] = []
    servers = config.get("mcp_servers", {})
    if not isinstance(servers, dict):
        return findings
    for name, server in servers.items():
        if not isinstance(server, dict) or server.get("command") != "npx":
            continue
        args = server.get("args", [])
        packages = [
            arg
            for arg in args
            if isinstance(arg, str) and not arg.startswith("-")
        ]
        if not packages:
            findings.append(
                Finding(path, 0, "command.unpinned", f"MCP server {name!r} has no pinned npx package")
            )
        for package in packages[:1]:
            if not npx_package_is_pinned(package):
                findings.append(
                    Finding(
                        path,
                        0,
                        "command.unpinned",
                        f"MCP server {name!r} must pin {package!r} to an exact version",
                    )
                )
    return findings


def validate_remote_write_defaults(root: Path, files: Sequence[str]) -> list[Finding]:
    findings: list[Finding] = []
    default_control_plane = (
        ".agents/roles/",
        ".agents/workflows/",
        ".agents/context/",
        ".agents/templates/",
        ".agents/skills/daypage/",
    )
    remote_write_files = [
        path
        for path in files
        if path in ROOT_CONTRACT_FILES
        or path == ".agents/README.md"
        or path.startswith(default_control_plane)
    ]
    for path in remote_write_files:
        text = read_text(root, path)
        if text is None:
            continue
        lines = text.splitlines()
        for number, line in enumerate(lines, start=1):
            if not DANGEROUS_REMOTE_WRITE.search(line):
                continue
            previous = lines[number - 2] if number >= 2 else ""
            if REMOTE_WRITE_MARKER not in previous and REMOTE_WRITE_MARKER not in line:
                findings.append(
                    Finding(
                        path,
                        number,
                        "remote-write.default",
                        "remote publish/write command requires an adjacent "
                        f"`{REMOTE_WRITE_MARKER}` opt-in marker",
                    )
                )
    return findings


def validate_contracts(root: Path) -> list[Finding]:
    files = all_known_files(root)
    findings: list[Finding] = []
    findings.extend(validate_manifest(root))
    findings.extend(validate_skills(root, files))
    findings.extend(validate_json_schemas(root, files))
    findings.extend(validate_personal_paths(root, files))
    findings.extend(validate_stale_project_facts(root, files))
    findings.extend(validate_tracked_runs(root))
    findings.extend(validate_codex_agents(root, files))
    findings.extend(validate_pinned_commands(root))
    findings.extend(validate_remote_write_defaults(root, files))
    return sorted(set(findings))


def check_environment() -> list[str]:
    messages: list[str] = []
    required = ("git", "python3")
    optional = ("swift", "node", "pnpm", "go")
    ios = ("xcrun", "xcodebuild")
    for command in required:
        path = shutil.which(command)
        messages.append(f"{'OK' if path else 'ERROR'} tool.{command}: {path or 'not found'}")
    for command in optional:
        path = shutil.which(command)
        messages.append(f"{'OK' if path else 'WARN'} tool.{command}: {path or 'not found'}")
    for command in ios:
        path = shutil.which(command)
        severity = "OK" if path else ("ERROR" if sys.platform == "darwin" else "WARN")
        messages.append(f"{severity} tool.{command}: {path or 'not found'}")
    return messages


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--environment",
        action="store_true",
        help="also inspect the local developer toolchain",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.root.resolve()
    if not (root / "AGENTS.md").is_file():
        print(f"ERROR [repo.root] {root}: AGENTS.md not found", file=sys.stderr)
        return 2

    findings = validate_contracts(root)
    for finding in findings:
        print(finding.render())

    environment_failed = False
    if args.environment:
        for message in check_environment():
            print(message)
            environment_failed = environment_failed or message.startswith("ERROR")

    if findings or environment_failed:
        print(f"Agent contract check failed with {len(findings)} finding(s).", file=sys.stderr)
        return 1
    print("Agent contract check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
